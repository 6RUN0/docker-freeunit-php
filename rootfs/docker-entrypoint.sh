#!/bin/sh
#
# Container entrypoint (run by tini). Portable POSIX sh, see
# docker-entrypoint-common.sh for the shell rules and the core functions.

set -e

. /docker-entrypoint-common.sh

# First, before any write and before any hook or /docker-entrypoint.d script:
# refuse root (re-exec as the image user when the capabilities allow it), then
# make sure the runtime dirs exist and are writable for the container user.
drop_root_or_die "$0" "$@"
prepare_runtime_dirs

# Hook contract. Child images extend the entrypoint by dropping *.sh into
# ENTRYPOINT_HOOK_DIR (kept separate from ENTRYPOINT_CONFIG_DIR, which holds
# runtime config). Its path is a readonly build-time constant on purpose: the
# loop below sources (`.`) these files into this POSIX sh, so it must not be
# redirectable by untrusted runtime env. A hook file:
#   - is POSIX sh (no bash syntax: it is parsed by /bin/sh, dash in the image);
#   - is root-owned and not group/world-writable (assert_safe_root_file), so a
#     compromised app cannot persist code into the next start;
#   - only defines functions handle_<cmd>, <cmd> made of [A-Za-z0-9_]: no
#     top-level side effects, no bare `trap`, no `set` changes - they would leak
#     into the launch path, and a failing last command aborts the start;
#   - names every variable it sets with its own prefix (e.g. `supercronic_` in
#     handle_supercronic): POSIX sh has no `local`, so an unprefixed name could
#     shadow the environment or another hook, and the names UNIT_*,
#     ENTRYPOINT_*, _ep_* belong to the entrypoint;
#   - does not redefine the core library functions.
# Files are sourced top-level only (non-recursive), in glob order. When a
# handler matches $1 (has_handler: `command -v`), dispatch_handler calls it with
# the full argv; it owns the launch and MUST exec the final process, and `set -e`
# is off inside it. This keeps THIS file authoritative - every
# robustness/security fix lands here and downstream images inherit it - without
# children copying it.
for _ep_hook in "$ENTRYPOINT_HOOK_DIR"/*.sh; do
    [ -f "$_ep_hook" ] || continue
    assert_safe_root_file "$_ep_hook"
    # shellcheck source=/dev/null  # handlers are provided by downstream images
    if ! . "$_ep_hook"; then
        die "failed to source entrypoint hook: $_ep_hook"
    fi
done

# No command was given (the image declares no CMD on purpose: an exec-form CMD
# cannot expand the UNIT_* single source, so the default launch lives here). Run
# the daemon in the foreground; the control/pid/state/tmp flags are added below
# from docker-entrypoint-common.sh, so nothing is duplicated.
if [ "$#" -eq 0 ]; then
    set -- "$UNIT_BINARY" --no-daemon
fi

# A matching handle_<cmd> owns the launch and must exec; dispatch_handler enforces
# that (it dies loudly if a handler returns or exits non-zero without exec'ing,
# instead of falling through to `exec "$@"` and double-running the command). It is
# a no-op when no handler matches, so the default launch path below runs.
dispatch_handler "$@"

# The daemon must use the paths the initial configuration wrote to: missing
# launch flags are added, a conflicting one dies (build_unit_launch_args).
# --version, --help and -h only print and exit: run them as given, with no
# configuration round.
if [ "${1:-}" = "$UNIT_BINARY" ] || [ "${1:-}" = "${UNIT_BINARY}-debug" ]; then
    _ep_info_only=
    for _ep_arg in "$@"; do
        case "$_ep_arg" in
            --version | --help | -h) _ep_info_only=1 ;;
        esac
    done
    if [ -z "$_ep_info_only" ]; then
        build_unit_launch_args "$@"
        # Unquoted on purpose: the extra args are readonly literals without
        # whitespace or glob characters, split on a space.
        _ep_ifs=$IFS
        IFS=' '
        # shellcheck disable=SC2086
        set -- "$@" $UNIT_LAUNCH_EXTRA_ARGS
        IFS=$_ep_ifs
        unit_initial_configuration "$1"
    fi
fi

exec "$@"
