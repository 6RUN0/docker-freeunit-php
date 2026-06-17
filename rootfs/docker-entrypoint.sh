#!/usr/bin/env bash

set -e
# nullglob: an unmatched glob expands to nothing (not the literal pattern);
# globstar: '**' matches files recursively. Together they replace the
# word-splitting `for f in $(find ...)` loops with space-safe, lexically
# sorted iteration over /docker-entrypoint.d.
shopt -s nullglob globstar

. /docker-entrypoint-common.sh

# Child images extend the entrypoint by dropping *.sh into ENTRYPOINT_HOOK_DIR
# (defined in docker-entrypoint-common.sh; kept separate from ENTRYPOINT_CONFIG_DIR,
# which holds runtime config). Its path is a readonly build-time constant on
# purpose: the loop below `source`s these files as root before any privilege
# drop, so it must not be redirectable by untrusted runtime env. Each file is
# sourced (top-level, non-recursive, lexical order) and must ONLY define a
# function named `handle_<command>`; it shares this shell's scope, so top-level
# side effects, a bare `trap`, or `set` changes leak into the launch path. When a
# handler matches $1 it owns the launch and MUST exec the final process. This
# keeps THIS file authoritative — every robustness/security fix lands here and
# downstream images inherit it — without children copying it. Each hook is
# vetted with assert_safe_root_file before sourcing: it runs as root in this
# shell, so a non-root-owned or world-writable file (an image built sloppily, or
# this dir accidentally bind-mounted from an untrusted volume) is refused rather
# than executed with full privileges.
for hook in "$ENTRYPOINT_HOOK_DIR"/*.sh; do
    [ -f "$hook" ] || continue
    assert_safe_root_file "$hook"
    # shellcheck source=/dev/null  # handlers are provided by downstream images
    if ! . "$hook"; then
        die "failed to source entrypoint hook: $hook"
    fi
done

# No command was given (the image declares no CMD on purpose: an exec-form CMD
# cannot expand the UNIT_* single source, so the default launch lives here). Run
# the daemon in the foreground against the control socket, with the binary name
# and socket path taken from docker-entrypoint-common.sh so nothing is duplicated.
if [ "$#" -eq 0 ]; then
    set -- "$UNIT_BINARY" --no-daemon --control "unix:$UNIT_CONTROL_SOCKET"
fi

# A matching handle_<cmd> owns the launch and must exec; dispatch_handler enforces
# that (it dies loudly if a handler returns or exits non-zero without exec'ing,
# instead of falling through to `exec "$@"` and double-running the command). It is
# a no-op when no handler matches, so the default launch path below runs.
dispatch_handler "$@"

if [ "${1:-}" = "$UNIT_BINARY" ] || [ "${1:-}" = "${UNIT_BINARY}-debug" ]; then
    unit_initial_configuration "$@"
fi

exec "$@"
