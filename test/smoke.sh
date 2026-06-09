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
  --php X.Y     PHP line to build (--build only; --php=X.Y is also accepted);
                default: parsed from the ref's 'phpX.Y' tag, else the Dockerfile
                ARG default
  -h, --help    show this help and exit
EOF
}

# shellcheck source=test/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
parse_test_args "$@"

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
config_dir="$(mktemp -d)"
chmod 0755 "$config_dir"

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$config_dir"
}
trap cleanup EXIT

# Print a failure message followed by the container's logs (the usual first thing
# to inspect when a run-time assertion fails) and exit non-zero. Args: <message>
fail_with_logs() {
    echo "FAIL: $1" >&2
    echo "---- container logs ----" >&2
    docker logs "$CONTAINER" >&2 || true
    exit 1
}

# *.json — applied as the Unit config; proven below by the app serving a request.
cp "$FIXTURES/config.json" "$config_dir/config.json"

# *.sh — executed during init; leaves a marker file we read back over docker exec.
cat > "$config_dir/10-marker.sh" <<EOF
#!/bin/sh
echo '$SCRIPT_MARKER' > '$SCRIPT_MARKER_FILE'
EOF
chmod +x "$config_dir/10-marker.sh"

# *.pem — a throwaway self-signed bundle uploaded to certificates/$CERT_NAME.
# Generated at run time (never committed) so no private key lands in the repo or
# trips a secret scanner; skipped with a warning where openssl is unavailable.
has_cert_fixture=
if command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj '/CN=freeunit-smoke' \
        -keyout "$config_dir/.key" -out "$config_dir/.crt" >/dev/null 2>&1
    cat "$config_dir/.crt" "$config_dir/.key" > "$config_dir/$CERT_NAME.pem"
    rm -f "$config_dir/.key" "$config_dir/.crt"
    has_cert_fixture=1
else
    echo "WARNING: openssl not found; skipping the *.pem certificate-upload check" >&2
fi

# Optionally build the image under test first, so one command covers the whole
# pipeline (build -> run -> assert).
build_image "$REPO_ROOT"

echo "==> starting $CONTAINER from $TEST_IMAGE_REF"
# Run under the hardened posture the README documents: drop all capabilities,
# keep only the two the root unitd master needs to drop workers to the app
# user/group, and forbid privilege escalation. This doubles as a regression
# guard -- --cap-drop=ALL strips CAP_DAC_OVERRIDE, so a non-root-owned
# /var/lib/unit would make the master fail to create its certs/scripts stores
# (the *.pem upload asserted below exercises exactly that path), which an
# unhardened run cannot catch.
docker run -d --name "$CONTAINER" \
    -p 127.0.0.1::8080 \
    --cap-drop=ALL \
    --cap-add=SETUID --cap-add=SETGID \
    --security-opt=no-new-privileges \
    -v "$FIXTURES/www:/www:ro" \
    -v "$config_dir:/docker-entrypoint.d:ro" \
    "$TEST_IMAGE_REF" >/dev/null

# Resolve the ephemeral host port docker mapped for container port 8080. We bind
# explicitly to 127.0.0.1, so pick that mapping line: on dual-stack hosts docker
# can also emit a '[::]:PORT' row, and a bare head -n1 could hand back an IPv6
# address that needs bracket handling the URL below does not do.
host_endpoint="$(docker port "$CONTAINER" 8080/tcp | grep -m1 '^127\.0\.0\.1:')"
url="http://${host_endpoint}/"
echo "==> app endpoint: $url"

echo "==> waiting for the app to respond"
body=""
app_responded=
for _ in $(seq 1 60); do
    if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
        fail_with_logs "container exited early"
    fi
    if body="$(curl -fsS "$url" 2>/dev/null)"; then
        app_responded=1
        break
    fi
    sleep 1
done

# Distinguish "never responded" (timeout) from "responded with the wrong body"
# (marker check below), so the failure message points at the real cause.
if [ -z "$app_responded" ]; then
    fail_with_logs "timed out after 60s waiting for the app to respond at $url"
fi

echo "==> response: ${body:-<empty>}"
if [[ "$body" != *"$MARKER"* ]]; then
    fail_with_logs "expected marker '$MARKER' in response"
fi
# Serving that response already proves the *.json config was applied.
echo "==> *.json config applied (the configured PHP app served the request)"

# *.sh: assert the entrypoint executed the script, via the marker file it wrote.
echo "==> verifying the entrypoint executed the *.sh script"
if ! script_out="$(docker exec "$CONTAINER" cat "$SCRIPT_MARKER_FILE" 2>/dev/null)"; then
    fail_with_logs "entrypoint script did not run; marker $SCRIPT_MARKER_FILE is missing"
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
if [ -n "$has_cert_fixture" ]; then
    echo "==> verifying the entrypoint uploaded the *.pem certificate bundle"
    cert_uploaded=
    for _ in $(seq 1 30); do
        if docker exec "$CONTAINER" curl -fsS -o /dev/null \
            --unix-socket /var/run/control.unit.sock \
            "http://localhost/certificates/$CERT_NAME" 2>/dev/null; then
            cert_uploaded=1
            break
        fi
        sleep 1
    done
    if [ -z "$cert_uploaded" ]; then
        fail_with_logs "certificate '$CERT_NAME' not retrievable from the control API"
    fi
    echo "==> *.pem uploaded (certificates/$CERT_NAME present)"
fi

# Confirm the daemon and module identify themselves (build-stage check, repeated
# at runtime so a broken module surfaces here too).
echo "==> unitd --version"
docker exec "$CONTAINER" unitd --version
echo "==> php -v"
docker exec "$CONTAINER" php -v

echo "PASS: $MARKER served by $TEST_IMAGE_REF"
