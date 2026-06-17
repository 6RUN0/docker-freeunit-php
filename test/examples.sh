#!/usr/bin/env bash
#
# Examples gate: keep the examples/ tree working against the maintained
# entrypoint contract. Two passes:
#
#   1. Static hardening lint (no Docker): every example's docker-compose.yml must
#      carry the canonical capability-hardening block, so a copied example never
#      silently drops cap_drop / no-new-privileges.
#   2. Live pass (Docker): build and run each example with `docker compose`, run
#      its README "Verify" checks, then `down -v`.
#
# The examples FROM the published GHCR base. Before going public that tag may not
# be pullable, so set EXAMPLES_BASE_IMAGE to a locally built image and this script
# retags it to the ref the examples expect. The Makefile passes the just-built
# default image, so `make test-examples` works right after a local build.
#
#   ./test/examples.sh                         # live pass against the GHCR base
#   EXAMPLES_BASE_IMAGE=freeunit-php:trixie-php8.4 ./test/examples.sh
#   EXAMPLES_LINT_ONLY=1 ./test/examples.sh    # static hardening lint only

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLES_DIR="$REPO_ROOT/examples"

# The base ref every example's FROM references. Retargeted from
# EXAMPLES_BASE_IMAGE when set (dev defaults to the same 8.4 line via .env).
EXPECTED_BASE='ghcr.io/6run0/freeunit-php:trixie-php8.4'

# The capability-hardening tokens every example compose must contain. This is the
# anti-drift guard: a copied example that forgot a control fails here.
HARDENING_TOKENS=(
    'cap_drop'
    'no-new-privileges'
    'SETUID'
    'SETGID'
)

log()  { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Pass 1: static hardening lint -----------------------------------------

lint_hardening() {
    log "linting hardening blocks in every example compose file"
    local compose found=0
    while IFS= read -r compose; do
        found=1
        local token
        for token in "${HARDENING_TOKENS[@]}"; do
            grep -qF "$token" "$compose" \
                || fail "$compose is missing hardening token '$token'"
        done
        echo "    ok: ${compose#"$REPO_ROOT"/}"
    done < <(find "$EXAMPLES_DIR" -mindepth 2 -maxdepth 2 -name docker-compose.yml | sort)
    [ "$found" = 1 ] || fail "no docker-compose.yml found under $EXAMPLES_DIR"
}

# --- Live pass helpers ------------------------------------------------------

# Run `docker compose` for the example in $1 with an isolated project name.
compose() {
    local example=$1; shift
    docker compose --project-directory "$EXAMPLES_DIR/$example" \
        -p "freeunit-ex-$example" "$@"
}

# Poll an URL until it responds successfully (curl -fsS, so HTTP < 400) or a
# timeout. Args: <url> [curl-opts...]
wait_http() {
    local url=$1; shift
    local _
    for _ in $(seq 1 60); do
        if curl -fsS -o /dev/null "$@" "$url" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# Fail unless <haystack> contains <needle>. Args: <needle> <haystack> <context>
assert_contains() {
    case "$2" in
        *"$1"*) : ;;
        *) fail "$3: expected to find '$1' in:\n$2" ;;
    esac
}

# Bring an example up (build), wait for the first listener, run its checks, then
# always tear it down. Args: <example> <check-fn>
run_example() {
    local example=$1 check=$2
    log "live: $example"
    # shellcheck disable=SC2064  # expand $example now for the trap
    trap "compose '$example' down -v --remove-orphans >/dev/null 2>&1 || true" RETURN
    compose "$example" up --build -d
    "$check"
    echo "    ok: $example"
}

# --- Per-example checks -----------------------------------------------------

check_basic() {
    wait_http http://localhost:8080/ || fail "basic: app did not respond on :8080"
    local body; body="$(curl -fsS http://localhost:8080/)"
    assert_contains 'served by PHP' "$body" basic
}

check_dev() {
    wait_http http://localhost:8080/ || fail "dev: app did not respond on :8080"
    local body; body="$(curl -fsS http://localhost:8080/)"
    assert_contains 'served by PHP' "$body" dev
    assert_contains 'wrote a timestamp' "$body" dev
    # The /data write must be owned by the unprivileged app user, not root.
    local owner; owner="$(compose dev exec -T app stat -c '%U' /data/visits.log)"
    [ "$owner" = freeunit ] || fail "dev: /data/visits.log owned by '$owner', expected 'freeunit'"
}

check_routing() {
    wait_http http://localhost:8080/ || fail "routing: site did not respond on :8080"
    local site admin css
    site="$(curl -fsS http://localhost:8080/)"
    assert_contains 'memory_limit = 256M' "$site" routing
    admin="$(curl -fsS http://localhost:8080/admin/)"
    assert_contains 'memory_limit = 512M' "$admin" routing
    css="$(curl -fsS -o /dev/null -w '%{http_code}' http://localhost:8080/assets/style.css)"
    [ "$css" = 200 ] || fail "routing: /assets/style.css returned $css, expected 200"
}

check_web_app() {
    wait_http https://localhost:8443/ -k || fail "web-app: TLS app did not respond on :8443"
    local redirect tls
    redirect="$(curl -ksI http://localhost:8080/)"
    assert_contains 'https://localhost:8443' "$redirect" web-app
    tls="$(curl -ks https://localhost:8443/)"
    assert_contains 'served over TLS' "$tls" web-app
}

check_cron_hook() {
    wait_http http://localhost:8080/ || fail "cron-hook: web role did not respond on :8080"
    local web; web="$(curl -fsS http://localhost:8080/)"
    assert_contains 'web role' "$web" cron-hook
    # The crontab uses supercronic's seven-field (per-second) syntax, so a tick
    # lands within a second; wait a few, then assert the cron job ran as the
    # dedicated worker user (uid 1500), not as freeunit.
    log "cron-hook: waiting up to 15s for a cron tick"
    local _ logs
    for _ in $(seq 1 15); do
        logs="$(compose cron-hook logs cron 2>/dev/null || true)"
        case "$logs" in
            *'uid=1500(worker)'*) echo "    cron ran as worker"; return 0 ;;
        esac
        sleep 1
    done
    fail "cron-hook: no 'uid=1500(worker)' cron line within 15s"
}

# --- Main -------------------------------------------------------------------

lint_hardening

if [ -n "${EXAMPLES_LINT_ONLY:-}" ]; then
    log "EXAMPLES_LINT_ONLY set; skipping the live pass"
    echo "PASS: hardening lint"
    exit 0
fi

command -v docker >/dev/null 2>&1 || fail "docker is required for the live pass (set EXAMPLES_LINT_ONLY=1 to skip)"

if [ -n "${EXAMPLES_BASE_IMAGE:-}" ]; then
    log "retagging $EXAMPLES_BASE_IMAGE -> $EXPECTED_BASE for the examples to build on"
    docker tag "$EXAMPLES_BASE_IMAGE" "$EXPECTED_BASE"
fi

run_example basic     check_basic
run_example dev       check_dev
run_example routing   check_routing
run_example web-app   check_web_app
run_example cron-hook check_cron_hook

echo "PASS: all examples built, ran, and verified"
