#!/usr/bin/env bash
#
# End-to-end smoke test: optionally build, then run the image with a populated
# /docker-entrypoint.d and assert the entrypoint processed every artifact type
# it supports:
#   *.sh    a shell script is executed (it writes a marker we read back)
#   *.pem   a certificate bundle is uploaded to the Unit control API
#   *.json  the app config is applied (proven by the app actually serving)
# This also proves the FreeUnit daemon starts, the embedded PHP module loads,
# the control socket accepts requests, and a request reaches PHP. The image runs
# without root; the scenarios cover the launch modes of that contract:
#   hardened  read-only, no capabilities, writable mounts, image user 65532
#   plain     no flags at all (writable layer, image user)
#   root      --user 0:0: drop to 65532 when allowed, die otherwise
#   any-uid   an arbitrary non-root uid:gid with its own tmpfs mounts
#   command   an explicit freeunitd command line gets the launch flags
#
#   ./test/smoke.sh freeunit-php:trixie-php8.4            # test a prebuilt image
#   ./test/smoke.sh --build freeunit-php:trixie-php8.5    # build it first, then test
#   ./test/smoke.sh --build --php 8.5 freeunit-php:dev    # build a chosen PHP line

set -euo pipefail

usage() {
    cat <<EOF
Usage: ${0##*/} [--build] [--php X.Y] <image-ref>

Run <image-ref> in each supported launch mode, feed the entrypoint a *.sh /
*.pem / *.json set through /docker-entrypoint.d, then assert each was processed
and the app is served.

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
CONTAINER_PREFIX="freeunit-smoke-$$"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$REPO_ROOT/test/fixtures"
NONROOT_ID=65532

# Markers the assertions below look for: the *.sh script writes SCRIPT_MARKER into
# SCRIPT_MARKER_FILE inside the container; the *.pem bundle lands under CERT_NAME.
SCRIPT_MARKER_FILE='/tmp/entrypoint-script-ran'
SCRIPT_MARKER='entrypoint-script-ok'
CERT_NAME='smoke-cert'
STDERR_MARKER='entrypoint-stderr-ok'

# Messages that mean a write or a privilege operation failed somewhere in the
# daemon or the entrypoint; none may appear in a healthy run.
LOG_ERROR_PATTERN='Read-only file system|Operation not permitted|Permission denied'

# Assemble a /docker-entrypoint.d in a temp dir so all three artifact types can be
# dropped in (only the *.json fixture is kept under version control).
config_dir="$(mktemp -d)"
chmod 0755 "$config_dir"
work_dir="$(mktemp -d)"
containers=()

cleanup() {
    local c
    for c in "${containers[@]}"; do
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
    rm -rf "$config_dir" "$work_dir"
}
trap cleanup EXIT

# Print a failure message followed by the container's logs (the usual first thing
# to inspect when a run-time assertion fails) and exit non-zero.
# Args: <container> <message>
fail_with_logs() {
    echo "FAIL: $2" >&2
    echo "---- container logs ($1) ----" >&2
    docker logs "$1" >&2 || true
    exit 1
}

# *.json - applied as the Unit config; proven below by the app serving a request.
cp "$FIXTURES/config.json" "$config_dir/config.json"

# *.sh - executed during init; leaves a marker file we read back over docker exec.
cat > "$config_dir/10-marker.sh" <<EOF
#!/bin/sh
echo '$SCRIPT_MARKER' > '$SCRIPT_MARKER_FILE'
EOF
chmod +x "$config_dir/10-marker.sh"

# A *.sh that reopens /dev/stderr: after a root start the entrypoint must have
# handed fd 2 to the image user too, or this fails the initial configuration.
cat > "$config_dir/20-stderr.sh" <<EOF
#!/bin/sh
echo '$STDERR_MARKER' > /dev/stderr
EOF
chmod +x "$config_dir/20-stderr.sh"

# *.pem - a throwaway self-signed bundle uploaded to certificates/$CERT_NAME.
# Generated at run time (never committed) so no private key lands in the repo or
# trips a secret scanner; skipped with a warning where openssl is unavailable.
# Mode 0644: the container user reads it from a bind mount owned by the host user.
has_cert_fixture=
if command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj '/CN=freeunit-smoke' \
        -keyout "$config_dir/.key" -out "$config_dir/.crt" >/dev/null 2>&1
    cat "$config_dir/.crt" "$config_dir/.key" > "$config_dir/$CERT_NAME.pem"
    rm -f "$config_dir/.key" "$config_dir/.crt"
    chmod 0644 "$config_dir/$CERT_NAME.pem"
    has_cert_fixture=1
else
    echo "WARNING: openssl not found; skipping the *.pem certificate-upload check" >&2
fi

# A 1 MiB upload: larger than Unit's in-memory body buffer, so the body goes
# through the daemon's --tmpdir, and PHP stores the file in its default temp dir;
# both are /tmp.
head -c 1048576 /dev/zero > "$work_dir/upload.bin"

# Optionally build the image under test first, so one command covers the whole
# pipeline (build -> run -> assert).
build_image "$REPO_ROOT"

# The read-only, capability-free posture the README documents, for <uid>:<gid>:
# every writable path is a tmpfs owned by the process (a site bind-mounts /tmp
# from disk instead; the test needs no host dir). HOME stays read-only (the
# image's /home/nonroot, or / for a uid without a passwd entry). Sets HARDENED_OPTS.
# Args: <uid> <gid>
set_hardened_opts() {
    local owner="uid=$1,gid=$2,mode=0700"
    HARDENED_OPTS=(
        --user "$1:$2"
        --read-only
        --cap-drop=ALL
        --security-opt=no-new-privileges
        --tmpfs "/run:size=16m,$owner"
        --tmpfs "/tmp:size=64m,$owner"
    )
}

# Start a detached container with the fixture app and config mounted and port
# 8080 published on 127.0.0.1. Args: <scenario> [docker-run-opts...] [-- cmd...]
start_container() {
    local name="$CONTAINER_PREFIX-$1"
    shift
    local -a opts=() cmd=()
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
        opts+=("$1")
        shift
    done
    [ "$#" -gt 0 ] && shift && cmd=("$@")
    containers+=("$name")
    echo "==> starting $name from $TEST_IMAGE_REF ${opts[*]} ${cmd[*]}"
    docker run -d --name "$name" \
        -p 127.0.0.1::8080 \
        -v "$FIXTURES/www:/www:ro" \
        -v "$config_dir:/docker-entrypoint.d:ro" \
        "${opts[@]}" \
        "$TEST_IMAGE_REF" "${cmd[@]}" >/dev/null
    CONTAINER=$name
}

# Wait until the app in CONTAINER answers and carries the marker; sets APP_URL
# and APP_BODY. Distinguishes "never responded" from "wrong body" so the failure
# points at the real cause.
wait_for_app() {
    local host_endpoint _
    # Resolve the ephemeral host port docker mapped for container port 8080. We
    # bind explicitly to 127.0.0.1, so pick that mapping line: on dual-stack hosts
    # docker can also emit a '[::]:PORT' row the URL below does not handle.
    host_endpoint="$(docker port "$CONTAINER" 8080/tcp | grep -m1 '^127\.0\.0\.1:')"
    APP_URL="http://${host_endpoint}/"
    APP_BODY=""
    for _ in $(seq 1 60); do
        if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
            fail_with_logs "$CONTAINER" "container exited early"
        fi
        if APP_BODY="$(curl -fsS "$APP_URL" 2>/dev/null)"; then
            if [[ "$APP_BODY" != *"$MARKER"* ]]; then
                fail_with_logs "$CONTAINER" "expected marker '$MARKER' in response, got '$APP_BODY'"
            fi
            echo "==> response: $APP_BODY"
            return 0
        fi
        sleep 1
    done
    fail_with_logs "$CONTAINER" "timed out after 60s waiting for the app to respond at $APP_URL"
}

# Assert every process of CONTAINER runs as <uid>, except PID 1 when <pid1-uid>
# is given: then PID 1 must be tini running as that uid. Args: <uid> [pid1-uid]
assert_process_uids() {
    local want=$1 want_init=${2:-$1} init_pid pid uid comm seen=0
    init_pid="$(docker inspect -f '{{.State.Pid}}' "$CONTAINER")"
    while read -r pid uid comm; do
        seen=$((seen + 1))
        if [ "$pid" = "$init_pid" ]; then
            [ "$comm" = tini ] || fail_with_logs "$CONTAINER" "PID 1 is '$comm', expected tini"
            [ "$uid" = "$want_init" ] \
                || fail_with_logs "$CONTAINER" "PID 1 runs as uid $uid, expected $want_init"
        elif [ "$uid" != "$want" ]; then
            fail_with_logs "$CONTAINER" "process $pid ($comm) runs as uid $uid, expected $want"
        fi
    done < <(docker top "$CONTAINER" -eo pid,uid,comm | tail -n +2)
    [ "$seen" -gt 1 ] || fail_with_logs "$CONTAINER" "docker top listed $seen processes"
    echo "==> processes run as uid $want (PID 1 tini: uid $want_init)"
}

# Assert the logs of CONTAINER carry none of LOG_ERROR_PATTERN.
assert_clean_logs() {
    local hits
    hits="$(docker logs "$CONTAINER" 2>&1 | grep -E "$LOG_ERROR_PATTERN" || true)"
    [ -z "$hits" ] || fail_with_logs "$CONTAINER" "write/privilege errors in the logs: $hits"
}

# Run the image in the foreground, expect a non-zero exit and <message> in the
# output. Args: <message> [docker-run-opts...] [-- cmd...]
assert_start_dies() {
    local message=$1 out ec
    shift
    echo "==> expecting a refusal: $*"
    local -a opts=() cmd=()
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
        opts+=("$1")
        shift
    done
    [ "$#" -gt 0 ] && shift && cmd=("$@")
    set +e
    out="$(timeout 60 docker run --rm "${opts[@]}" "$TEST_IMAGE_REF" "${cmd[@]}" 2>&1)"
    ec=$?
    set -e
    if [ "$ec" -eq 0 ]; then
        echo "FAIL: the container started with $*; expected a refusal. Output: $out" >&2
        exit 1
    fi
    if [[ "$out" != *"$message"* ]]; then
        echo "FAIL: exit $ec without '$message' in the output: $out" >&2
        exit 1
    fi
    echo "==> refused (exit $ec): $message"
}

echo "### hardened: read-only, no capabilities, image user"
set_hardened_opts "$NONROOT_ID" "$NONROOT_ID"
start_container hardened "${HARDENED_OPTS[@]}"
wait_for_app
# Serving that response already proves the *.json config was applied.
echo "==> *.json config applied (the configured PHP app served the request)"
if [[ "$APP_BODY" != *"session.save_path=/tmp"* ]]; then
    fail_with_logs "$CONTAINER" "expected session.save_path=/tmp from the embed SAPI"
fi

# *.sh: assert the entrypoint executed the script, via the marker file it wrote.
echo "==> verifying the entrypoint executed the *.sh script"
if ! script_out="$(docker exec "$CONTAINER" cat "$SCRIPT_MARKER_FILE" 2>/dev/null)"; then
    fail_with_logs "$CONTAINER" "entrypoint script did not run; marker $SCRIPT_MARKER_FILE is missing"
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
            --unix-socket /var/run/control.freeunit.sock \
            "http://localhost/certificates/$CERT_NAME" 2>/dev/null; then
            cert_uploaded=1
            break
        fi
        sleep 1
    done
    if [ -z "$cert_uploaded" ]; then
        fail_with_logs "$CONTAINER" "certificate '$CERT_NAME' not retrievable from the control API"
    fi
    echo "==> *.pem uploaded (certificates/$CERT_NAME present)"
fi

echo "==> POSTing a 1 MiB file"
upload_body="$(curl -fsS -F "upload=@$work_dir/upload.bin" "$APP_URL")" \
    || fail_with_logs "$CONTAINER" "the 1 MiB upload failed"
if [[ "$upload_body" != *"upload_dir=/tmp upload_size=1048576"* ]]; then
    fail_with_logs "$CONTAINER" "expected the upload in /tmp, got '$upload_body'"
fi
echo "==> upload stored in /tmp"

assert_process_uids "$NONROOT_ID"
assert_clean_logs
docker exec "$CONTAINER" /docker-healthcheck.sh \
    || fail_with_logs "$CONTAINER" "the healthcheck failed"
echo "==> the healthcheck passes"

# Confirm the daemon and module identify themselves (build-stage check, repeated
# at runtime so a broken module surfaces here too).
echo "==> freeunitd --version"
docker exec "$CONTAINER" freeunitd --version
echo "==> php -v"
docker exec "$CONTAINER" php -v

echo "### plain: no flags, writable layer"
start_container plain
wait_for_app
assert_process_uids "$NONROOT_ID"
assert_clean_logs

echo "### root: --user 0:0 with the default capabilities drops to $NONROOT_ID"
for tty in no yes; do
    tty_opts=()
    [ "$tty" = yes ] && tty_opts=(-t)
    start_container "root-tty-$tty" --user 0:0 "${tty_opts[@]}"
    wait_for_app
    assert_process_uids "$NONROOT_ID" 0
    # Captured first: grep -q closing the pipe early would fail it under pipefail.
    logs="$(docker logs "$CONTAINER" 2>&1)"
    [[ "$logs" == *'started as root; dropping'* ]] \
        || fail_with_logs "$CONTAINER" "no root-drop warning in the logs"
    # The Unit log goes to /dev/stdout: the dropped daemon could reopen it.
    [[ "$logs" =~ unit\ [0-9.]+\ started ]] \
        || fail_with_logs "$CONTAINER" "the Unit log did not reach docker logs"
    [[ "$logs" == *"$STDERR_MARKER"* ]] \
        || fail_with_logs "$CONTAINER" "the *.sh could not write to /dev/stderr"
    assert_clean_logs
done

echo "==> a shell started as root reopens /dev/stderr after the drop"
out="$(timeout 60 docker run --rm --user 0:0 "$TEST_IMAGE_REF" \
    bash -c 'echo stderr-reopened >/dev/stderr' 2>&1)" \
    || { echo "FAIL: /dev/stderr not writable after the root drop: $out" >&2; exit 1; }
[[ "$out" == *stderr-reopened* ]] || { echo "FAIL: no stderr output: $out" >&2; exit 1; }

echo "### root-min-caps: --user 0:0 with only SETUID, SETGID, CHOWN, KILL"
start_container root-min-caps --user 0:0 --cap-drop=ALL \
    --cap-add=SETUID --cap-add=SETGID --cap-add=CHOWN --cap-add=KILL
wait_for_app
assert_process_uids "$NONROOT_ID" 0
# Docker runs the HEALTHCHECK as the container user, root here, which lacks
# CAP_DAC_OVERRIDE for the 0600 socket of 65532.
docker exec "$CONTAINER" /docker-healthcheck.sh \
    || fail_with_logs "$CONTAINER" "the healthcheck failed as the container user root"
docker stop -t 20 "$CONTAINER" >/dev/null
stop_code="$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER")"
logs="$(docker logs "$CONTAINER" 2>&1)"
[ "$stop_code" = 0 ] || fail_with_logs "$CONTAINER" "docker stop ended with exit $stop_code"
[[ "$logs" != *"FATAL tini"* ]] || fail_with_logs "$CONTAINER" "tini could not forward the stop signal"
echo "==> healthcheck as root and a clean docker stop (exit 0)"

assert_start_dies "without CAP_SETUID/CAP_SETGID/CAP_CHOWN" --user 0:0 --cap-drop=ALL
assert_start_dies "without CAP_SETUID/CAP_SETGID/CAP_CHOWN" --user 0:0 \
    --cap-drop=ALL --cap-add=SETUID --cap-add=SETGID
assert_start_dies "CAP_KILL" --user 0:0 \
    --cap-drop=ALL --cap-add=SETUID --cap-add=SETGID --cap-add=CHOWN
assert_start_dies "with group 0 among its groups" --user 12345:0
assert_start_dies "with group 0 among its groups" --group-add 0

echo "### any-uid: --user 12345:12345, read-only, own tmpfs mounts"
set_hardened_opts 12345 12345
start_container any-uid "${HARDENED_OPTS[@]}"
wait_for_app
assert_process_uids 12345
assert_clean_logs

echo "### any-uid-root-probe: --user 12345:12345 with the default capabilities"
start_container any-uid-root-probe --user 12345:12345 \
    --tmpfs /run:size=16m,uid=12345,gid=12345,mode=0700 \
    --tmpfs /tmp:size=64m,uid=12345,gid=12345,mode=0700
wait_for_app
# A root probe (docker exec -u 0) switches to the owner of the socket, 12345.
docker exec -u 0 "$CONTAINER" /docker-healthcheck.sh \
    || fail_with_logs "$CONTAINER" "the healthcheck failed as root for a 12345-owned socket"
echo "==> the root probe reaches the socket of uid 12345"

echo "### command: an explicit freeunitd command line"
# Without --no-daemon: the entrypoint adds it, or freeunitd would fork away and
# the container would exit.
start_container command -- freeunitd
wait_for_app
assert_clean_logs
for info_flag in --version --help -h; do
    echo "==> freeunitd $info_flag with config mounted skips initial configuration"
    out="$(timeout 60 docker run --rm -v "$config_dir:/docker-entrypoint.d:ro" \
        "$TEST_IMAGE_REF" freeunitd "$info_flag" 2>&1)" \
        || { echo "FAIL: freeunitd $info_flag failed: $out" >&2; exit 1; }
    [[ "$out" == *"unit "* && "$out" != *"initial configuration"* ]] \
        || { echo "FAIL: unexpected freeunitd $info_flag output: $out" >&2; exit 1; }
done
assert_start_dies "conflicts with the entrypoint path" -- freeunitd --no-daemon --statedir /var/lib/freeunit

echo "PASS: $MARKER served by $TEST_IMAGE_REF in every launch mode"
