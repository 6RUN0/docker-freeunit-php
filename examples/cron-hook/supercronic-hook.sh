#!/usr/bin/env bash
#
# Entrypoint hook: add a "supercronic" launch mode to the freeunit-php image.
#
# This file is COPYed into /docker-entrypoint-hook.d/ and SOURCED by the base
# entrypoint as root, before any privilege drop. Per the hook contract it must
# ONLY define handle_<cmd> functions (no top-level side effects), and a handler
# MUST exec the final process -- returning or exiting non-zero is a fatal
# contract violation the dispatcher reports loudly.
#
# Running the image with `supercronic` as its command makes the entrypoint's
# dispatch_handler call handle_supercronic, which owns the launch instead of the
# default unitd path. That is the whole point of the hook system: the SAME image
# gains a second role (a long-lived cron runner beside the Unit web server)
# without overwriting /docker-entrypoint.sh, so every base-entrypoint robustness
# and security fix still applies here.

handle_supercronic() {
    # Path baked in by this example's Dockerfile. Declared local (not a top-level
    # constant) to keep this file's global scope to handler definitions only, as
    # the contract requires.
    local crontab=/etc/supercronic/crontab

    # Run any operator *.sh drop-ins first -- the same convenience the web role
    # gets from the first-run routine (a no-op when none are present).
    # run_entrypoint_scripts is a public core-library function and needs no
    # running daemon, so it is safe on this Unit-less launch path.
    run_entrypoint_scripts

    log_notice "starting supercronic cron runner ($crontab)"

    # Drop root -> the app user and exec the runner, so supercronic becomes the
    # container's main process and receives signals directly. exec_as_user uses
    # setpriv, which needs CAP_SETUID/CAP_SETGID (granted in docker-compose.yml,
    # the same two capabilities the Unit master uses to drop workers).
    exec_as_user "$APPLICATION_USER" "$APPLICATION_GROUP" \
        supercronic "$crontab"
}
