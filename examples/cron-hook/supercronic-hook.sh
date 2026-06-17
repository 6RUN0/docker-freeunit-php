#!/usr/bin/env bash
#
# Entrypoint hook: a worked TEMPLATE for adding a launch mode to the
# freeunit-php image. supercronic is just the concrete command here -- the
# patterns below (matching by command word, forwarding operator flags,
# env-overridable defaults, dropping privileges, reusing the core library)
# apply to ANY companion command you wire in the same way.
#
# This file is COPYed into /docker-entrypoint-hook.d/ and SOURCED by the base
# entrypoint as root, before any privilege drop. Per the hook contract it must
# ONLY define handle_<cmd> functions (no top-level side effects, no bare `trap`,
# no shadowing core-library names or the UNIT_*/ENTRYPOINT_*/APPLICATION_*
# variables), and a handler MUST exec the final process -- returning or exiting
# non-zero is a fatal contract violation the dispatcher reports loudly.
#
# Dispatch recap: the entrypoint calls `dispatch_handler "$@"`, which invokes
# `handle_<$1> "$@"` when a matching function exists. So the handler is selected
# by the command WORD ($1), and it receives the FULL argv -- the command word
# followed by everything the operator appended after it. Running the image as
#
#   command: ["supercronic", "-debug", "-split-logs"]     # docker-compose
#   docker run IMG supercronic -debug -split-logs          # docker run
#
# therefore reaches handle_supercronic as: supercronic -debug -split-logs.

handle_supercronic() {
    # $1 is the command word ("supercronic"). shift it off so "$@" holds ONLY the
    # extra arguments the operator passed after the command -- that is the whole
    # mechanism for forwarding flags into a hook.
    shift

    # Operator-overridable settings: an env var with an explicit default, so
    # there is no hidden magic. A child image bakes a different default with ENV,
    # and `docker run -e SUPERCRONIC_CRONTAB=...` retargets it at runtime. Declare
    # everything `local` -- the file's global scope must stay handler-only.
    local crontab="${SUPERCRONIC_CRONTAB:-/etc/supercronic/crontab}"

    # Built-in default flags as an ARRAY, not a string: array expansion keeps
    # multi-word or space-containing values intact, where an unquoted string
    # would word-split. Empty here by default; add your own, e.g.
    #   local -a default_opts=(-passthrough-logs)
    # Operator flags ("$@") are placed AFTER these, so when the target honors
    # last-one-wins an operator flag overrides a baked-in default.
    local -a default_opts=()

    # Reuse a public core-library routine: run any operator *.sh drop-ins first,
    # the same convenience the web role gets from the first-run routine (a no-op
    # when none are present). It needs no running daemon, so it is safe on this
    # Unit-less launch path. log_notice/log_info likewise come from the library.
    run_entrypoint_scripts

    # Provision a DEDICATED user for the cron role instead of reusing `freeunit`, to
    # show programmatic user provisioning from a hook and least privilege (cron
    # jobs run under their own identity). setup_user is a public core-library
    # routine and is idempotent, so calling it on every start is safe. We use a
    # NEW name `worker`: APPLICATION_UID is ignored for the pre-existing `freeunit`
    # user (the core package's postinst already created it with a system UID), so
    # a custom uid is only honored for a user we create here. The uid/gid 1500
    # must be free -- setup_user dies actionably if it is taken.
    local cron_user="worker"
    setup_user "$cron_user" 1500 "$cron_user" 1500

    log_notice "starting supercronic cron runner ($crontab) as $cron_user"

    # Command layout: <binary> <our defaults> <operator flags> <positional arg>.
    # Operator flags go after the defaults (override) and before the positional
    # crontab path, which supercronic expects last. EVERY expansion is quoted, so
    # flags and paths containing spaces survive intact.
    #
    # exec_as_user drops root -> `worker` via setpriv and execs, so the target
    # becomes the container's main process and receives signals directly. setpriv
    # needs CAP_SETUID/CAP_SETGID (granted in docker-compose.yml -- the same two
    # capabilities the Unit master uses to drop its workers).
    exec_as_user "$cron_user" "$cron_user" \
        supercronic "${default_opts[@]}" "$@" "$crontab"
}
