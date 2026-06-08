#!/usr/bin/env bash
#
# End-to-end smoke test: optionally build, then run the image with a populated
# /docker-entrypoint.d and assert the entrypoint processed every artifact type
# it supports:
#   *.sh    a shell script is executed (it writes a marker we read back)
#   *.pem   a certificate bundle is uploaded to the Unit control API
#   *.json  the app config is applied (proven by the app actually serving)
# This also proves the FreeUnit daemon starts, the embedded PHP module loads,
# the control socket accepts requests, and a request reaches PHP.
#
#   ./test/smoke.sh freeunit-php:trixie-php8.4            # test a prebuilt image
#   ./test/smoke.sh --build freeunit-php:trixie-php8.5    # build it first, then test
#   ./test/smoke.sh --build --php 8.5 freeunit-php:dev    # build a chosen PHP line

set -euo pipefail

usage() {
    cat <<EOF
Usage: ${0##*/} [--build] [--php X.Y] <image-ref>

Run <image-ref>, feed the entrypoint a *.sh / *.pem / *.json set through
/docker-entrypoint.d, then assert each was processed and the app is served.

  <image-ref>   image to test, e.g. freeunit-php:trixie-php8.4
  --build       docker build <image-ref> from the repo root before testing
  --php X.Y     PHP line to build (--build only); default: parsed from the ref's
                'phpX.Y' tag, else the Dockerfile ARG default
  -h, --help    show this help and exit
EOF
}

do_build=
php_ver=
positional=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --build) do_build=1; shift ;;
        --php) php_ver="${2:?--php requires a value}"; shift 2 ;;
        --php=*) php_ver="${1#*=}"; shift ;;
        --) shift; positional+=("$@"); break ;;
        -*) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
        *) positional+=("$1"); shift ;;
    esac
done
set -- "${positional[@]}"
if [ "$#" -lt 1 ]; then
    usage >&2
    exit 1
fi

IMAGE_REF=$1
MARKER='freeunit-php-smoke-ok'
CONTAINER="freeunit-smoke-$$"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$REPO_ROOT/test/fixtures"

# Markers the assertions below look for: the *.sh script writes SCRIPT_MARKER into
# SCRIPT_MARKER_FILE inside the container; the *.pem bundle lands under CERT_NAME.
SCRIPT_MARKER_FILE='/var/tmp/entrypoint-script-ran'
SCRIPT_MARKER='entrypoint-script-ok'
CERT_NAME='smoke-cert'

# Assemble a /docker-entrypoint.d in a temp dir so all three artifact types can be
# dropped in (only the *.json fixture is kept under version control).
entrypoint_d="$(mktemp -d)"
chmod 0755 "$entrypoint_d"

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$entrypoint_d"
}
trap cleanup EXIT

# *.json — applied as the Unit config; proven below by the app serving a request.
cp "$FIXTURES/config.json" "$entrypoint_d/config.json"

# *.sh — executed during init; leaves a marker file we read back over docker exec.
cat > "$entrypoint_d/10-marker.sh" <<EOF
#!/bin/sh
echo '$SCRIPT_MARKER' > '$SCRIPT_MARKER_FILE'
EOF
chmod +x "$entrypoint_d/10-marker.sh"

# *.pem — a throwaway self-signed bundle uploaded to certificates/$CERT_NAME.
# Generated at run time (never committed) so no private key lands in the repo or
# trips a secret scanner; skipped with a warning where openssl is unavailable.
cert_check=
if command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj '/CN=freeunit-smoke' \
        -keyout "$entrypoint_d/.key" -out "$entrypoint_d/.crt" >/dev/null 2>&1
    cat "$entrypoint_d/.crt" "$entrypoint_d/.key" > "$entrypoint_d/$CERT_NAME.pem"
    rm -f "$entrypoint_d/.key" "$entrypoint_d/.crt"
    cert_check=1
else
    echo "WARNING: openssl not found; skipping the *.pem certificate-upload check" >&2
fi

# Optionally build the image under test first, so one command covers the whole
# pipeline (build -> run -> assert). PHP_VER is the only build-arg that varies
# here; SUITE / FREEUNIT_* fall back to their Dockerfile ARG defaults. The PHP
# line comes from --php, else from the ref's 'phpX.Y' tag, else the ARG default.
if [ -n "$do_build" ]; then
    if [ -z "$php_ver" ] && [[ "$IMAGE_REF" =~ php([0-9]+\.[0-9]+) ]]; then
        php_ver="${BASH_REMATCH[1]}"
    fi
    build_args=()
    if [ -n "$php_ver" ]; then
        build_args+=(--build-arg "PHP_VER=$php_ver")
    fi
    echo "==> building $IMAGE_REF${php_ver:+ (PHP $php_ver)}"
    docker build "${build_args[@]}" -t "$IMAGE_REF" "$REPO_ROOT"
fi

echo "==> starting $CONTAINER from $IMAGE_REF"
docker run -d --name "$CONTAINER" \
    -p 127.0.0.1::8080 \
    -v "$FIXTURES/www:/www:ro" \
    -v "$entrypoint_d:/docker-entrypoint.d:ro" \
    "$IMAGE_REF" >/dev/null

# Resolve the ephemeral host port docker mapped for container port 8080.
host_addr="$(docker port "$CONTAINER" 8080/tcp | head -n1)"
url="http://${host_addr}/"
echo "==> app endpoint: $url"

echo "==> waiting for the app to respond"
body=""
ready=
for _ in $(seq 1 60); do
    if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
        echo "FAIL: container exited early" >&2
        docker logs "$CONTAINER" >&2 || true
        exit 1
    fi
    if body="$(curl -fsS "$url" 2>/dev/null)"; then
        ready=1
        break
    fi
    sleep 1
done

# Distinguish "never responded" (timeout) from "responded with the wrong body"
# (marker check below), so the failure message points at the real cause.
if [ -z "$ready" ]; then
    echo "FAIL: timed out after 60s waiting for the app to respond at $url" >&2
    echo "---- container logs ----" >&2
    docker logs "$CONTAINER" >&2 || true
    exit 1
fi

echo "==> response: ${body:-<empty>}"
if [[ "$body" != *"$MARKER"* ]]; then
    echo "FAIL: expected marker '$MARKER' in response" >&2
    echo "---- container logs ----" >&2
    docker logs "$CONTAINER" >&2 || true
    exit 1
fi
# Serving that response already proves the *.json config was applied.
echo "==> *.json config applied (the configured PHP app served the request)"

# *.sh: assert the entrypoint executed the script, via the marker file it wrote.
echo "==> verifying the entrypoint executed the *.sh script"
if ! script_out="$(docker exec "$CONTAINER" cat "$SCRIPT_MARKER_FILE" 2>/dev/null)"; then
    echo "FAIL: entrypoint script did not run; marker $SCRIPT_MARKER_FILE is missing" >&2
    echo "---- container logs ----" >&2
    docker logs "$CONTAINER" >&2 || true
    exit 1
fi
if [ "$script_out" != "$SCRIPT_MARKER" ]; then
    echo "FAIL: script marker mismatch: got '$script_out', want '$SCRIPT_MARKER'" >&2
    exit 1
fi
echo "==> *.sh executed (marker: $script_out)"

# *.pem: assert the entrypoint uploaded the bundle, visible via the control API.
# The control socket is served by Unit's controller, which after the post-config
# daemon restart can come up a moment later than the router that already answered
# the HTTP request above, so poll instead of probing once (otherwise flaky on a
# slow runner).
if [ -n "$cert_check" ]; then
    echo "==> verifying the entrypoint uploaded the *.pem certificate bundle"
    cert_ok=
    for _ in $(seq 1 30); do
        if docker exec "$CONTAINER" curl -fsS -o /dev/null \
            --unix-socket /var/run/control.unit.sock \
            "http://localhost/certificates/$CERT_NAME" 2>/dev/null; then
            cert_ok=1
            break
        fi
        sleep 1
    done
    if [ -z "$cert_ok" ]; then
        echo "FAIL: certificate '$CERT_NAME' not retrievable from the control API" >&2
        echo "---- container logs ----" >&2
        docker logs "$CONTAINER" >&2 || true
        exit 1
    fi
    echo "==> *.pem uploaded (certificates/$CERT_NAME present)"
fi

# Confirm the daemon and module identify themselves (build-stage check, repeated
# at runtime so a broken module surfaces here too).
echo "==> unitd --version"
docker exec "$CONTAINER" unitd --version
echo "==> php -v"
docker exec "$CONTAINER" php -v

echo "PASS: $MARKER served by $IMAGE_REF"
