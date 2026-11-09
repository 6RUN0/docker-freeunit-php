#!/bin/sh
# shellcheck disable=SC2329  # tests and helpers are discovered and called by name at run time
#
# Unit checks for the error/timeout paths of docker-entrypoint-common.sh that the
# end-to-end smoke test cannot reach (it only exercises the happy path). They run
# INSIDE the image, under its /bin/sh (dash), so the real library is sourced as
# shipped and with the shell the entrypoint uses. POSIX sh, like the library.
# test/entrypoint-lib.sh mounts this file and runs it; it is not run on the host.
#
# Structured like a pytest suite, in shell: test_* functions are auto-discovered,
# assertions live in a small assert_* library, and the runner prints an
# "N passed, M failed" summary. Each test runs in its own fresh shell (the runner
# re-execs `--run-test`), so stubs and variables cannot leak between tests.
#
#   sh entrypoint-lib-cases.sh --in-container     # every test
#   sh entrypoint-lib-cases.sh --run-test <name>  # one test

LIB=${ENTRYPOINT_LIB:-/docker-entrypoint-common.sh}
SHELL_UNDER_TEST=${ENTRYPOINT_LIB_SHELL:-sh}

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

# Source the library under test. die()/log_*() write to fd3; tests that inspect
# their output capture fd2+fd3 via `2>&1 3>&1` at the call site.
# shellcheck disable=SC1090  # LIB is the in-image library, resolved at runtime
_load_lib() { . "$LIB"; }

# Source a copy of the library with some readonly literals replaced, for the
# tests that need a short tick budget or a different path. Pre-binding a
# readonly variable does not work in POSIX sh: the library's own `readonly X=`
# is then a fatal error of a special builtin. Args: NAME=VALUE...
_load_lib_with() {
    _t_patched=$(mktemp)
    cp "$LIB" "$_t_patched"
    for _t_pair in "$@"; do
        sed -i "s|^readonly ${_t_pair%%=*}=.*|readonly ${_t_pair}|" "$_t_patched"
        grep -q "^readonly ${_t_pair}\$" "$_t_patched" || _fail "no readonly literal ${_t_pair%%=*} to patch"
    done
    # shellcheck disable=SC1090
    . "$_t_patched"
}

# --- Tests ----------------------------------------------------------------

# A bind-mounted *.sh without the execute bit must die with an actionable
# message instead of falling through to an opaque exit 126.
test_nonexecutable_script_dies() {
    _load_lib
    dir=$(mktemp -d)
    : >"$dir/bad.sh" # created without the execute bit
    # Command substitution so die()'s exit ends only the subshell, not the test.
    err=$(run_entrypoint_scripts "$dir" 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "run_entrypoint_scripts should die on a non-executable *.sh"
    assert_contains "$err" "not executable" "the die message should be actionable"
}

# The appliers walk the dir recursively in byte order, skip hidden entries (a
# ConfigMap's ..data) and keep names with spaces whole; a script failure ends
# the caller (no pipeline subshell swallows the die).
test_run_entrypoint_scripts_order_and_names() {
    _load_lib
    dir=$(mktemp -d)
    log=$(mktemp)
    mkdir -p "$dir/sub dir" "$dir/..data"
    for name in "20-b.sh" "10-a.sh" "sub dir/30 c.sh" "..data/99-hidden.sh"; do
        printf '#!/bin/sh\necho "%s" >>"%s"\n' "$name" "$log" >"$dir/$name"
        chmod +x "$dir/$name"
    done
    run_entrypoint_scripts "$dir" 3>/dev/null
    assert_eq "$(tr '\n' '|' <"$log")" "10-a.sh|20-b.sh|sub dir/30 c.sh|" "byte order, recursive, hidden skipped"

    printf '#!/bin/sh\nexit 4\n' >"$dir/15-fail.sh"
    chmod +x "$dir/15-fail.sh"
    err=$(run_entrypoint_scripts "$dir" 2>&1 3>&1; echo "reached-after-loop")
    assert_contains "$err" "entrypoint script failed (exit 4)" "the failure is reported"
    case "$err" in
        *reached-after-loop*) _fail "die inside the loop must end the shell" ;;
    esac
}

# assert_safe_root_file guards the hook files the dispatcher sources: a root-owned,
# non-world-writable file of the image passes; a file the container process owns
# (it could rewrite it) and a world-writable one are refused. The suite runs as
# the image user, so mktemp files are owned by the process.
test_assert_safe_root_file_rejects_unsafe() {
    _load_lib
    assert_safe_root_file /docker-entrypoint-common.sh \
        || _fail "a root-owned file of the image must pass"

    dir=$(mktemp -d)
    : >"$dir/own"
    chmod 0644 "$dir/own"
    err=$(assert_safe_root_file "$dir/own" 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "a file owned by the container process must be rejected"
    assert_contains "$err" "unsafe ownership" "the die message names the reason"

    : >"$dir/evil"
    chmod 0666 "$dir/evil" # world-writable
    err=$(assert_safe_root_file "$dir/evil" 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "a world-writable file must be rejected"
}

# stop_unit must read the pid defensively: a missing or empty pidfile signals
# nothing, and a multi-line pidfile yields exactly one target (the first line).
test_stop_unit_reads_pid_safely() {
    _load_lib
    sock=/definitely/not/a.sock # not a socket -> the socket fallback is skipped
    kill_log=$(mktemp)
    # Stub the kill builtin (a function wins over a regular builtin in POSIX
    # command search) so stop_unit records its targets and signals nothing real.
    # `kill -0` is the liveness probe stop_unit's wait loop uses; answer it
    # "process gone" (exit 1) so the loop ends after the single TERM.
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
# accepts it should die, not spin forever. A 3-tick budget makes the timeout
# fire in well under a second.
test_wait_for_control_socket_times_out() {
    _load_lib_with UNIT_READY_TIMEOUT_TICKS=3
    err=$(wait_for_control_socket /definitely/not/a.sock 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "wait_for_control_socket should die when the socket never accepts"
    assert_contains "$err" "did not accept requests within" "the die message names the timeout"
}

# stop_unit must escalate to SIGKILL when the process never dies under TERM.
test_stop_unit_escalates_to_sigkill() {
    _load_lib_with UNIT_STOP_TIMEOUT_TICKS=2
    sock=/definitely/not/a.sock # unused once a pid is present; keeps the loop on the pid path
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

# has_handler finds a shell function by `command -v`; an executable of the
# same name in PATH or a command word that cannot be a function name is no
# handler.
test_has_handler() {
    _load_lib
    # shellcheck disable=SC2329  # looked up by has_handler
    handle_foo() { :; }
    has_handler foo || _fail "a defined handle_foo must be found"
    has_handler nosuch && _fail "an undefined handler must not be found"
    bin=$(mktemp -d)
    printf '#!/bin/sh\n' >"$bin/handle_bar"
    chmod +x "$bin/handle_bar"
    PATH=$bin:$PATH has_handler bar && _fail "an executable handle_bar in PATH is no handler"
    has_handler 'foo-bar' && _fail "a command word with '-' is no handler"
    has_handler '' && _fail "an empty command word is no handler"
    return 0
}

# dispatch_handler must enforce the hook contract: a handler that returns instead
# of exec'ing is a fatal error with an actionable message.
test_dispatch_handler_requires_exec() {
    _load_lib
    # shellcheck disable=SC2329  # invoked indirectly by dispatch_handler
    handle_foo() { return 0; } # returns without exec'ing
    err=$(dispatch_handler foo 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "a handler returning without exec must die"
    assert_contains "$err" "returned without exec" "the die message names the contract violation"
}

# A handler that exits non-zero must also die with the diagnostic, not abort the
# entrypoint silently under set -e before the message.
test_dispatch_handler_nonzero_return_dies() {
    _load_lib
    # shellcheck disable=SC2329  # invoked indirectly by dispatch_handler
    handle_foo() { return 3; }
    err=$(dispatch_handler foo 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "a handler exiting non-zero must die, not abort silently"
    assert_contains "$err" "exited 3" "the die message reports the handler's exit code"
}

# A handler that execs replaces the shell with its target and receives the
# full argv, the command word first.
test_dispatch_handler_exec_gets_argv() {
    _load_lib
    # shellcheck disable=SC2329  # invoked indirectly by dispatch_handler
    handle_foo() { exec printf '%s|' "$@"; }
    out=$(dispatch_handler foo -x "a b" 2>&1 3>&1)
    assert_eq "$out" "foo|-x|a b|" "the handler gets the command word and the args intact"
}

# With no matching handler, dispatch_handler must be a no-op so the caller falls
# through to its default launch path.
test_dispatch_handler_no_match_is_noop() {
    _load_lib
    dispatch_handler nosuchcommand
    ec=$?
    assert_eq "$ec" 0 "no matching handler -> dispatch_handler is a no-op"
}

# The Dockerfile creates the image user from these literals' values and the root
# guard drops to them: the passwd entry must name exactly them.
test_nonroot_literals_match_passwd() {
    _load_lib
    assert_eq "$(id -u nonroot)" "$UNIT_NONROOT_UID" "nonroot uid"
    assert_eq "$(id -g nonroot)" "$UNIT_NONROOT_GID" "nonroot gid"
    assert_eq "$(getent passwd nonroot | cut -d: -f6)" "$UNIT_NONROOT_HOME" "nonroot home"
    assert_eq "$(id -u)" "$UNIT_NONROOT_UID" "the suite runs as the image user"
}

# The entrypoint runs under the image's /bin/sh; the suite runs under it too.
test_shell_is_image_sh() {
    assert_eq "$(readlink -f /bin/sh)" /usr/bin/dash "the image /bin/sh"
}

# Under read_only /tmp is the only writable temp dir; PHP sessions default to
# the root-owned /var/lib/php/sessions and must be pointed at /tmp (the embed
# SAPI reads the same conf.d file; the smoke test checks it through Unit).
test_php_session_save_path_is_tmp() {
    assert_eq "$(php -r 'echo ini_get("session.save_path");')" /tmp "session.save_path"
}

# drop_root_or_die is a no-op for a non-root process without group 0.
test_drop_root_or_die_noop_for_nonroot() {
    _load_lib
    drop_root_or_die true || _fail "drop_root_or_die must return 0 for the image user"
}

# has_effective_cap reads CapEff: the image user has an empty effective set.
test_has_effective_cap_unprivileged() {
    _load_lib
    has_effective_cap 5 && _fail "the image user must have no CAP_KILL"
    return 0
}

# prepare_runtime_dirs creates the state and generated dirs as the image user.
test_prepare_runtime_dirs_creates_dirs() {
    _load_lib
    prepare_runtime_dirs 2>/dev/null 3>&1 || _fail "prepare_runtime_dirs must succeed as the image user"
    [ -d "$UNIT_STATE_DIR" ] || _fail "$UNIT_STATE_DIR was not created"
    [ -d "$ENTRYPOINT_GENERATED_DIR" ] || _fail "$ENTRYPOINT_GENERATED_DIR was not created"
}

# A read-only temp dir must fail with the mount hint, not as an EROFS in Unit.
test_prepare_runtime_dirs_dies_on_readonly_dir() {
    _load_lib_with UNIT_TMP_DIR=/usr
    err=$(prepare_runtime_dirs 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "a non-writable temp dir must die"
    assert_contains "$err" "/usr is not writable" "the die message names the dir"
    assert_contains "$err" "bind-mount" "the die message says what to mount"
}

# A state dir that cannot be created (no tmpfs at /run) must die with the hint.
test_prepare_runtime_dirs_dies_on_unwritable_run() {
    _load_lib_with UNIT_STATE_DIR=/proc/freeunit-state
    err=$(prepare_runtime_dirs 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "an uncreatable state dir must die"
    assert_contains "$err" "--tmpfs /run" "the die message says what to mount"
}

# A read-only HOME (the passwd-less HOME=/ of an arbitrary uid, or a read_only
# image) is accepted: ssh, composer and drush work without writing there.
test_prepare_runtime_dirs_accepts_readonly_home() {
    _load_lib
    HOME=/ prepare_runtime_dirs 2>/dev/null 3>&1 || _fail "a read-only HOME must not stop the start"
}

# An explicit freeunitd command line gets the missing launch flags; a flag with
# the entrypoint's value (either spelling) is kept once, another value dies.
test_build_unit_launch_args() {
    _load_lib
    all=" --no-daemon --control unix:$UNIT_CONTROL_SOCKET --pid $UNIT_PID_FILE --statedir $UNIT_STATE_DIR --tmpdir $UNIT_TMP_DIR"
    build_unit_launch_args freeunitd
    assert_eq "$UNIT_LAUNCH_EXTRA_ARGS" "$all" "every flag is added, --no-daemon included"

    build_unit_launch_args freeunitd --no-daemon
    assert_eq "$UNIT_LAUNCH_EXTRA_ARGS" "${all# --no-daemon}" "a given --no-daemon is not repeated"

    build_unit_launch_args freeunitd-debug --statedir "$UNIT_STATE_DIR" --tmpdir="$UNIT_TMP_DIR" --no-daemon
    assert_eq "$UNIT_LAUNCH_EXTRA_ARGS" \
        " --control unix:$UNIT_CONTROL_SOCKET --pid $UNIT_PID_FILE" \
        "matching flags are not repeated"

    err=$(build_unit_launch_args freeunitd --no-daemon --statedir /var/lib/freeunit 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "a conflicting --statedir must die"
    assert_contains "$err" "conflicts with the entrypoint path" "the die message names the conflict"

    err=$(build_unit_launch_args freeunitd --pid 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "a flag without a value must die"
}

# unit_initial_configuration runs the *.sh of the config dir only, uploads the
# certificates of both dirs before any config, and PUTs the generated config
# last. The daemon and the control API are stubbed; the dirs are patched.
test_unit_initial_configuration_applies_generated_last() {
    root=$(mktemp -d)
    mkdir -p "$root/config" "$root/generated" "$root/state"
    _load_lib_with "ENTRYPOINT_CONFIG_DIR=$root/config" \
        "ENTRYPOINT_GENERATED_DIR=$root/generated" "UNIT_STATE_DIR=$root/state"
    put_log=$root/put.log
    : >"$put_log"
    # shellcheck disable=SC2329  # invoked indirectly by unit_initial_configuration
    start_unit() { :; }
    # shellcheck disable=SC2329
    wait_for_control_socket() { :; }
    # shellcheck disable=SC2329
    stop_unit() { :; }
    # shellcheck disable=SC2329
    curl_put() { printf '%s %s\n' "$2" "${1##*/}" >>"$put_log"; }

    printf '#!/bin/sh\n: >%s\n' "$root/config-ran" >"$root/config/10-run.sh"
    printf '#!/bin/sh\n: >%s\n' "$root/generated-ran" >"$root/generated/10-run.sh"
    chmod +x "$root/config/10-run.sh" "$root/generated/10-run.sh"
    : >"$root/config/baked.pem"
    : >"$root/config/baked.json"
    : >"$root/generated/rendered.pem"
    : >"$root/generated/rendered.json"

    out=$(unit_initial_configuration freeunitd 2>&1 3>&1) || _fail "initial configuration failed: $out"
    [ -e "$root/config-ran" ] || _fail "the *.sh of the config dir must run"
    [ ! -e "$root/generated-ran" ] || _fail "a *.sh of the generated dir must not run"
    assert_eq "$(tr '\n' ' ' <"$put_log")" \
        "certificates/baked baked.pem certificates/rendered rendered.pem config baked.json config rendered.json " \
        "certificates of both dirs first, then config, generated last"
    assert_contains "$out" "ignoring $root/generated/10-run.sh" "the skipped script is reported"
}

# A failing initial configuration runs the EXIT trap, which wipes the state and
# generated dirs so the next start retries.
test_unit_initial_configuration_failure_wipes_state() {
    root=$(mktemp -d)
    mkdir -p "$root/config" "$root/generated" "$root/state"
    _load_lib_with "ENTRYPOINT_CONFIG_DIR=$root/config" \
        "ENTRYPOINT_GENERATED_DIR=$root/generated" "UNIT_STATE_DIR=$root/state" \
        "UNIT_PID_FILE=$root/none.pid" UNIT_STOP_TIMEOUT_TICKS=1
    # shellcheck disable=SC2329
    start_unit() { : >"$root/state/conf.json"; : >"$root/generated/x.json"; }
    # shellcheck disable=SC2329
    wait_for_control_socket() { :; }
    printf '#!/bin/sh\nexit 5\n' >"$root/config/10-fail.sh"
    chmod +x "$root/config/10-fail.sh"
    # The fds are redirected inside the subshell: the EXIT trap runs after the
    # redirections of the failing call are undone (dash).
    out=$(exec 2>&1 3>&1; unit_initial_configuration freeunitd)
    ec=$?
    assert_nonzero "$ec" "a failing script must fail the initial configuration"
    assert_contains "$out" "initial configuration failed" "the trap reports the failure"
    [ -z "$(find "$root/state" "$root/generated" -mindepth 1)" ] || _fail "state and generated dirs must be wiped"
}

# A SIGTERM during the initial configuration (docker stop) must exit 143 through
# the EXIT trap and wipe the state like a failure. The script signals the shell
# running the round; the trap fires once the script returns.
test_unit_initial_configuration_sigterm_wipes_state() {
    root=$(mktemp -d)
    mkdir -p "$root/config" "$root/generated" "$root/state"
    _load_lib_with "ENTRYPOINT_CONFIG_DIR=$root/config" \
        "ENTRYPOINT_GENERATED_DIR=$root/generated" "UNIT_STATE_DIR=$root/state" \
        "UNIT_PID_FILE=$root/none.pid" UNIT_STOP_TIMEOUT_TICKS=1
    # shellcheck disable=SC2329
    start_unit() { : >"$root/state/conf.json"; }
    # shellcheck disable=SC2329
    wait_for_control_socket() { :; }
    # shellcheck disable=SC2016  # $PPID belongs to the generated script
    printf '#!/bin/sh\nkill -TERM "$PPID"\n: >%s\n' "$root/script-done" >"$root/config/10-term.sh"
    printf '#!/bin/sh\n: >%s\n' "$root/next-ran" >"$root/config/20-next.sh"
    chmod +x "$root/config/10-term.sh" "$root/config/20-next.sh"
    out=$(exec 2>&1 3>&1; unit_initial_configuration freeunitd)
    ec=$?
    assert_eq "$ec" 143 "SIGTERM exits 143"
    [ -e "$root/script-done" ] || _fail "the signalling script must run to its end"
    [ ! -e "$root/next-ran" ] || _fail "no script may run after the SIGTERM"
    assert_contains "$out" "initial configuration failed (exit 143)" "the EXIT trap handles the signal"
    [ -z "$(find "$root/state" -mindepth 1)" ] || _fail "the state dir must be wiped"
}

# Appliers refuse a dangling symlink with an entrypoint name and an unreadable
# subdirectory, instead of a misleading error or silently skipping files.
test_appliers_refuse_bad_entries() {
    _load_lib
    dir=$(mktemp -d)
    ln -s /nonexistent "$dir/10-dangling.sh"
    err=$(run_entrypoint_scripts "$dir" 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "a dangling *.sh link must die"
    assert_contains "$err" "not a regular file" "the die message names the cause"

    dir=$(mktemp -d)
    mkdir "$dir/target"
    ln -s "$dir/target" "$dir/config.json"
    err=$(apply_config "$dir" 2>&1 3>&1)
    ec=$?
    assert_nonzero "$ec" "a *.json link to a directory must die"
    assert_contains "$err" "not a regular file" "the die message names the cause"

    dir=$(mktemp -d)
    mkdir "$dir/locked"
    : >"$dir/locked/x.json"
    chmod 000 "$dir/locked"
    err=$(apply_config "$dir" 2>&1 3>&1)
    ec=$?
    chmod 755 "$dir/locked"
    assert_nonzero "$ec" "an unreadable subdirectory must die"
    assert_contains "$err" "cannot list" "the die message names the dir"
}

# dir_has_content underpins is_first_run, so its empty/non-empty boundary must be
# exact: nested-only content still counts (mindepth 1), an empty dir does not.
test_dir_has_content_boundary() {
    _load_lib
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
    sed -n 's/^\(test_[A-Za-z0-9_]*\)() {$/\1/p' "$0" | LC_ALL=C sort
}

run_all() {
    passed=0
    failed=0
    for t in $(discover_tests); do
        if "$SHELL_UNDER_TEST" "$0" --run-test "$t"; then
            printf '  PASS %s\n' "$t"
            passed=$((passed + 1))
        else
            printf '  FAIL %s\n' "$t"
            failed=$((failed + 1))
        fi
    done
    printf '\n%d passed, %d failed (of %d)\n' "$passed" "$failed" "$((passed + failed))"
    [ "$failed" -eq 0 ]
}

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
    *)
        echo "usage: ${0##*/} --in-container | --run-test <name>" >&2
        exit 2
        ;;
esac
