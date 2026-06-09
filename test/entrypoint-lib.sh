#!/usr/bin/env bash
#
# Unit checks for the error/timeout paths of docker-entrypoint-common.sh that the
# end-to-end smoke test cannot reach (it only exercises the happy path). They run
# INSIDE the image so the real library is sourced as shipped.
#
# Structured like a pytest suite, in shell: test_* functions are auto-discovered,
# assertions live in a small assert_* library, fixtures clean up via trap, and
# the runner prints an "N passed, M failed" summary. Each test runs in its own
# fresh shell (the runner re-execs `--run-test`), because the timeout-budget
# tests pre-bind a readonly tick budget that must be set before the library is
# sourced and cannot be reset within one shell.
#
#   ./test/entrypoint-lib.sh freeunit-php:trixie-php8.4          # test a prebuilt image
#   ./test/entrypoint-lib.sh --build freeunit-php:trixie-php8.5  # build it first, then test
#   ./test/entrypoint-lib.sh --build --php 8.5 freeunit-php:dev  # build a chosen PHP line
#
# Sourcing the library on the host is unsafe (it provisions the app user via
# groupadd/useradd on load), so every mode below runs in the container.

LIB=${ENTRYPOINT_LIB:-/docker-entrypoint-common.sh}

# --- Assertion library (pytest-style) -------------------------------------
# Each raises by exiting non-zero, which the runner counts as a failed test.

_fail() {
    printf '    assertion failed: %s\n' "$*" >&2
    exit 1
}

assert_eq() { # <actual> <expected> [message]
    [ "$1" = "$2" ] || _fail "${3:-assert_eq}: expected [$2], got [$1]"
}

assert_nonzero() { # <exit-code> [message]
    [ "$1" -ne 0 ] || _fail "${2:-assert_nonzero}: expected a non-zero exit, got 0"
}

assert_contains() { # <haystack> <needle> [message]
    case "$1" in
    *"$2"*) ;;
    *) _fail "${3:-assert_contains}: [$1] does not contain [$2]" ;;
    esac
}

assert_socket() { # <path> [message]
    [ -S "$1" ] || _fail "${2:-assert_socket}: [$1] is not a socket"
}

# Source the library under test. die()/log_*() write to fd3; tests that inspect
# their output capture fd2+fd3 via `2>&1 3>&1` at the call site.
# shellcheck disable=SC1090  # LIB is the in-image library, resolved at runtime
_load_lib() { . "$LIB" 2>/dev/null; }

# --- Tests ----------------------------------------------------------------

# A bind-mounted *.sh without the execute bit must die with an actionable
# message instead of falling through to an opaque exit 126.
test_nonexecutable_script_dies() {
    _load_lib
    local dir err ec
    dir=$(mktemp -d)
    : >"$dir/bad.sh" # created without the execute bit
    # Command substitution so die()'s exit ends only the subshell, not the test.
    err=$(run_entrypoint_scripts "$dir" 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "run_entrypoint_scripts should die on a non-executable *.sh"
    assert_contains "$err" "not executable" "the die message should be actionable"
}

# assert_safe_root_file guards files the dispatcher sources as root: a root-owned,
# non-world-writable file passes; a world-writable one (anyone could rewrite the
# root-run content) is refused. Tests run as root in the image, so mktemp files
# are root-owned and only the permission bits need flipping to exercise both arms.
test_assert_safe_root_file_rejects_unsafe() {
    _load_lib
    local dir err ec
    dir=$(mktemp -d)
    : >"$dir/safe"
    chmod 0644 "$dir/safe"
    assert_safe_root_file "$dir/safe" || _fail "a root-owned 0644 file must pass"

    : >"$dir/evil"
    chmod 0666 "$dir/evil" # world-writable
    err=$(assert_safe_root_file "$dir/evil" 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "a world-writable file must be rejected"
    assert_contains "$err" "unsafe ownership" "the die message names the reason"
}

# stop_unit must read the pid defensively: a missing or empty pidfile signals
# nothing, and a multi-line pidfile yields exactly one target (the first line).
test_stop_unit_reads_pid_safely() {
    _load_lib
    local kill_log pidfile
    local sock=/definitely/not/a.sock # not a socket -> the socket fallback is skipped
    kill_log=$(mktemp)
    # Stub the kill builtin (a function wins over the builtin at call time) so
    # stop_unit records its targets and signals nothing real. `kill -0` is the
    # liveness probe stop_unit's wait loop uses; answer it "process gone" (exit 1)
    # so the loop ends after the single TERM instead of spinning to the timeout.
    # shellcheck disable=SC2329  # invoked indirectly by stop_unit
    kill() {
        case "$1" in
            -0) return 1 ;;
            *) printf 'kill %s\n' "$*" >>"$kill_log" ;;
        esac
    }

    : >"$kill_log"
    stop_unit /no/such/pidfile "$sock"
    assert_eq "$(grep -c . "$kill_log")" 0 "missing pidfile -> no kill"

    pidfile=$(mktemp)
    : >"$pidfile"
    : >"$kill_log"
    stop_unit "$pidfile" "$sock"
    assert_eq "$(grep -c . "$kill_log")" 0 "empty pidfile -> no kill"

    pidfile=$(mktemp)
    printf '123\n456\n' >"$pidfile"
    : >"$kill_log"
    stop_unit "$pidfile" "$sock"
    assert_eq "$(grep -c . "$kill_log")" 1 "multi-line pidfile -> exactly one kill"
    assert_contains "$(cat "$kill_log")" "kill -TERM 123" "kills only the first pid line"

    # A pidfile without a trailing newline: `read` returns non-zero at EOF even
    # though it assigned the value, so a naive `read pid && kill` would skip the
    # TERM. read_pid must still yield the pid here.
    pidfile=$(mktemp)
    printf '4242' >"$pidfile" # no trailing newline
    : >"$kill_log"
    stop_unit "$pidfile" "$sock"
    assert_contains "$(cat "$kill_log")" "kill -TERM 4242" "newline-less pidfile still signals TERM"

    # A non-numeric pidfile must be ignored, not passed to kill (no kill -TERM foo,
    # no broad kill -TERM -1 from a stray '-1').
    pidfile=$(mktemp)
    printf 'garbage\n' >"$pidfile"
    : >"$kill_log"
    stop_unit "$pidfile" "$sock"
    assert_eq "$(grep -c . "$kill_log")" 0 "non-numeric pidfile -> no kill"
}

# wait_for_control_socket must bound its wait: against a socket that never
# accepts it should die, not spin forever. Pre-bind the tick budget so the
# timeout fires in well under a second; the library's own `readonly ...=300`
# is then rejected and 3 stands. This hinges on the library declaring its tick
# budgets with `readonly`: a re-`readonly` of an already-readonly variable fails
# (silently, under _load_lib's `2>/dev/null`), so our pre-bound value survives.
# A plain `X=...` assignment there would clobber it and this test would hang.
test_wait_for_control_socket_times_out() {
    # shellcheck disable=SC2034  # consumed by wait_for_control_socket after _load_lib
    readonly UNIT_READY_TIMEOUT_TICKS=3
    _load_lib
    local err ec
    err=$(wait_for_control_socket /definitely/not/a.sock 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "wait_for_control_socket should die when the socket never accepts"
    assert_contains "$err" "did not accept requests within" "the die message names the timeout"
}

# stop_unit must escalate to SIGKILL when the process never dies under TERM.
test_stop_unit_escalates_to_sigkill() {
    # shellcheck disable=SC2034  # consumed by stop_unit after _load_lib
    readonly UNIT_STOP_TIMEOUT_TICKS=2
    _load_lib
    local sock=/definitely/not/a.sock # unused once a pid is present; keeps the loop on the pid path
    local kill_log pidfile out
    kill_log=$(mktemp)
    # Simulate a master that ignores TERM: record the signals, and report the pid
    # as perpetually alive (`kill -0` succeeds) so the wait loop runs to the tick
    # budget and takes the SIGKILL branch.
    # shellcheck disable=SC2329  # invoked indirectly by stop_unit
    kill() {
        case "$1" in
            -0) return 0 ;;
            *) printf 'kill %s\n' "$*" >>"$kill_log" ;;
        esac
    }
    pidfile=$(mktemp)
    echo 4242 >"$pidfile"
    out=$(stop_unit "$pidfile" "$sock" 2>&1 3>&1)

    assert_contains "$(cat "$kill_log")" "kill -TERM 4242" "first signals TERM"
    assert_contains "$(cat "$kill_log")" "kill -KILL 4242" "then escalates to KILL"
    assert_contains "$out" "SIGKILL" "warns about the SIGKILL escalation"
}

# dispatch_handler must enforce the hook contract: a handler that returns instead
# of exec'ing is a fatal error with an actionable message.
test_dispatch_handler_requires_exec() {
    _load_lib
    # shellcheck disable=SC2329  # invoked indirectly by dispatch_handler
    handle_foo() { return 0; } # returns without exec'ing
    local err ec
    err=$(dispatch_handler foo 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "a handler returning without exec must die"
    assert_contains "$err" "returned without exec" "the die message names the contract violation"
}

# A handler that exits non-zero must also die with the diagnostic, not abort the
# entrypoint silently under set -e before the message (the original defect).
test_dispatch_handler_nonzero_return_dies() {
    _load_lib
    # shellcheck disable=SC2329  # invoked indirectly by dispatch_handler
    handle_foo() { return 3; }
    local err ec
    err=$(dispatch_handler foo 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "a handler exiting non-zero must die, not abort silently"
    assert_contains "$err" "exited 3" "the die message reports the handler's exit code"
}

# With no matching handler, dispatch_handler must be a no-op so the caller falls
# through to its default launch path.
test_dispatch_handler_no_match_is_noop() {
    _load_lib
    local ec
    dispatch_handler nosuchcommand
    ec=$?
    assert_eq "$ec" 0 "no matching handler -> dispatch_handler is a no-op"
}

# exec_as_user is the whole justification for not shipping gosu/su-exec, yet had
# no coverage. Assert it actually drops to the target user (nobody/nogroup ship in
# the image). It execs, so run it in a child shell and read back what it became.
test_exec_as_user_drops_privileges() {
    local out
    # shellcheck disable=SC1090  # LIB is the in-image library
    out=$(bash -c '. "$1" 2>/dev/null; exec_as_user nobody nogroup id -un' _ "$LIB")
    assert_eq "$out" "nobody" "exec_as_user runs the command as the target user"
}

# setup_user must reject a non-numeric id rather than passing it to useradd.
test_setup_user_rejects_non_numeric_id() {
    _load_lib
    local err ec
    err=$(setup_user appuser notanumber appgroup 1000 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "setup_user must reject a non-numeric uid"
    assert_contains "$err" "must be numeric" "the die message explains the numeric requirement"
}

# setup_user must be idempotent for an existing user/group ('unit' exists from the
# package postinst and the library load): keep its ids, log, and succeed.
test_setup_user_existing_is_idempotent() {
    _load_lib
    local out ec
    out=$(setup_user unit 4242 unit 4242 2>&1 3>&1)
    ec=$?
    assert_eq "$ec" 0 "provisioning an existing user/group must succeed (idempotent)"
    assert_contains "$out" "already exists" "it logs that the existing id is kept"
}

# setup_user must fail with an actionable message when the requested id is free by
# name but the numeric gid/uid is already taken, instead of letting groupadd's
# bare failure abort startup under set -e with no hint at the cause.
test_setup_user_rejects_id_collision() {
    _load_lib
    local err ec
    # Occupy gid 4243 so the new group's -g 4243 collides (uid 5000 stays free, so
    # the group step is the one that fails).
    groupadd -g 4243 collide_holder 2>/dev/null || true
    err=$(setup_user newuser 5000 newgroup 4243 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "setup_user must fail when the gid is already in use"
    assert_contains "$err" "already in use" "the die message explains the id collision"
}

# dir_has_content underpins is_first_run, so its empty/non-empty boundary must be
# exact: nested-only content still counts (mindepth 1), an empty dir does not.
test_dir_has_content_boundary() {
    _load_lib
    local empty full nested
    empty=$(mktemp -d)
    dir_has_content "$empty" && _fail "an empty dir must report no content"

    full=$(mktemp -d)
    : >"$full/file"
    dir_has_content "$full" || _fail "a dir with a file must report content"

    nested=$(mktemp -d)
    mkdir -p "$nested/sub"
    : >"$nested/sub/file"
    dir_has_content "$nested" || _fail "nested-only content must still count"

    return 0
}

# --- Runner ---------------------------------------------------------------

discover_tests() {
    compgen -A function | grep '^test_' | sort
}

run_all() {
    local t rc=0 passed=0 failed=0
    local -a tests
    mapfile -t tests < <(discover_tests)
    for t in "${tests[@]}"; do
        # Fresh shell per test: isolates the readonly tick budgets and the kill
        # stub, mirroring pytest's per-test isolation.
        if bash "$0" --run-test "$t"; then
            printf '  PASS %s\n' "$t"
            passed=$((passed + 1))
        else
            printf '  FAIL %s\n' "$t"
            failed=$((failed + 1))
            rc=1
        fi
    done
    printf '\n%d passed, %d failed (of %d)\n' "$passed" "$failed" "${#tests[@]}"
    return "$rc"
}

# --- Mode dispatch --------------------------------------------------------
case "${1:-}" in
--run-test)
    t=${2:?--run-test requires a test name}
    case "$t" in
    test_*) "$t" ;;
    *)
        echo "not a test: $t" >&2
        exit 2
        ;;
    esac
    exit
    ;;
--in-container)
    run_all
    exit
    ;;
esac

# --- Host mode: build (optional) and run the suite in the image -----------
set -euo pipefail

usage() {
    cat <<EOF
Usage: ${0##*/} [--build] [--php X.Y] <image-ref>

Run the docker-entrypoint-common.sh unit checks inside <image-ref>.

  <image-ref>   image to test, e.g. freeunit-php:trixie-php8.4
  --build       docker build <image-ref> from the repo root before testing
  --php X.Y     PHP line to build (--build only; --php=X.Y is also accepted);
                default: parsed from the ref's 'phpX.Y' tag, else the Dockerfile
                ARG default
  -h, --help    show this help and exit
EOF
}

# Sourced only in host mode: the --run-test / --in-container modes above run
# inside the container, where only this script is mounted (not test/lib.sh).
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=test/lib.sh
. "$(dirname "$SELF")/lib.sh"
parse_test_args "$@"
build_image "$REPO_ROOT"

# Mount this script read-only and re-exec it in --in-container mode. --entrypoint
# bash bypasses docker-entrypoint.sh so its startup (which provisions the app
# user) does not pollute the test output.
echo "==> running entrypoint-library checks in $TEST_IMAGE_REF"
if docker run --rm --entrypoint bash \
    -v "$SELF:/entrypoint-lib-test.sh:ro" \
    "$TEST_IMAGE_REF" /entrypoint-lib-test.sh --in-container; then
    echo "PASS: entrypoint-library checks passed in $TEST_IMAGE_REF"
else
    echo "FAIL: entrypoint-library checks failed in $TEST_IMAGE_REF" >&2
    exit 1
fi
