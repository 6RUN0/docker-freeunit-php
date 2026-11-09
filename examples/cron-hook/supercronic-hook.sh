#!/bin/sh
#
# Entrypoint hook: a worked TEMPLATE for adding a launch mode to the
# freeunit-php image. supercronic is just the concrete command here -- the
# patterns below (matching by command word, forwarding operator flags,
# env-overridable defaults, reusing the core library) apply to ANY companion
# command you wire in the same way.
#
# This file is COPYed into /docker-entrypoint-hook.d/ and SOURCED (`.`) by the
# base entrypoint, a POSIX sh (dash in the image) that already runs as the
# non-root container user. Per the hook contract it is POSIX sh too, ONLY
# defines handle_<cmd> functions (no top-level side effects, no bare `trap`, no
# redefining core-library functions), prefixes every variable it sets with its
# own name (`supercronic_`: there is no `local`, and UNIT_*, ENTRYPOINT_* and
# _ep_* belong to the entrypoint), and a handler MUST exec the final process --
# returning or exiting non-zero is a fatal contract violation the dispatcher
# reports loudly. `set -e` is off inside a handler: check errors explicitly.
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
    # mechanism for forwarding flags into a hook. The positional parameters are
    # the function's own, the one list POSIX sh keeps per call.
    shift

    # Operator-overridable settings: an env var with an explicit default, so
    # there is no hidden magic. A child image bakes a different default with ENV,
    # and `docker run -e SUPERCRONIC_CRONTAB=...` retargets it at runtime.
    supercronic_crontab=${SUPERCRONIC_CRONTAB:-/etc/supercronic/crontab}

    # Built-in default flags go IN FRONT of the operator flags, through the
    # positional parameters (the one space-safe list in POSIX sh), so when the
    # target honors last-one-wins an operator flag overrides a baked-in default.
    # None by default; add your own, e.g.
    #   set -- -passthrough-logs "$@"

    # Reuse a public core-library routine: run any operator *.sh drop-ins first,
    # the same convenience the web role gets from the first-run routine (a no-op
    # when none are present). It needs no running daemon, so it is safe on this
    # Unit-less launch path. log_notice/log_info likewise come from the library.
    run_entrypoint_scripts

    log_notice "starting supercronic cron runner ($supercronic_crontab) as uid $(id -u)"

    # Command layout: <binary> <defaults + operator flags> <positional arg>. The
    # crontab path goes last, where supercronic expects it. EVERY expansion is
    # quoted, so flags and paths containing spaces survive intact.
    #
    # exec makes the target the container's main process (under tini), so it
    # receives signals directly. No privilege drop: the entrypoint already runs as
    # the container user, so the jobs run as that user too.
    exec supercronic "$@" "$supercronic_crontab"
}
