#!/usr/bin/env bash

set -e
# nullglob: an unmatched glob expands to nothing (not the literal pattern);
# globstar: '**' matches files recursively. Together they replace the
# word-splitting `for f in $(find ...)` loops with space-safe, lexically
# sorted iteration over /docker-entrypoint.d.
shopt -s nullglob globstar

. /docker-entrypoint-common.sh

# Wipe the half-written state if the first-run configuration fails, so the next
# start re-runs initialization cleanly instead of booting a partial config
# (a non-empty /var/lib/unit makes the block below skip initialization).
config_failed() {
    local code=$?
    [ "$code" -eq 0 ] && return 0
    ngx_notice "initial configuration failed (exit $code); wiping /var/lib/unit/ so it is retried on next start"
    if [ -f /var/run/unit.pid ]; then
        kill -TERM "$(cat /var/run/unit.pid)" 2>/dev/null || true
    fi
    find /var/lib/unit -mindepth 1 -delete 2>/dev/null || true
}

if [ "$1" = "unitd" ] || [ "$1" = "unitd-debug" ]; then
    if find "/var/lib/unit/" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
        ngx_notice "/var/lib/unit/ is not empty, skipping initial configuration..."
    else
        if find "/docker-entrypoint.d/" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
            trap config_failed EXIT

            ngx_info "/docker-entrypoint.d/ is not empty, launching Unit daemon to perform initial configuration..."
            # Pass --pid explicitly so the path we kill below is the path unitd
            # writes, independent of FreeUnit's compile-time default.
            /usr/sbin/"$1" --control unix:/var/run/control.unit.sock --pid /var/run/unit.pid

            # The socket file appearing does not mean unitd accepts requests yet,
            # so poll the control API until it actually replies. A bare `curl`
            # here would abort the script under `set -e` on a connection-refused
            # blip (socket created, not yet listening) and trip the EXIT trap,
            # wiping /var/lib/unit; the loop tolerates those transient failures.
            until curl -fsS --unix-socket /var/run/control.unit.sock http://localhost/ >/dev/null 2>&1; do
                ngx_info "waiting for control socket to accept requests..."
                sleep 0.1
            done

            ngx_info "looking for shell scripts in /docker-entrypoint.d/..."
            for f in /docker-entrypoint.d/**/*.sh; do
                ngx_info "launching $f"
                "$f"
            done

            ngx_info "looking for certificate bundles in /docker-entrypoint.d/..."
            for f in /docker-entrypoint.d/**/*.pem; do
                ngx_info "uploading certificates bundle: $f"
                curl_put "$f" "certificates/$(basename "$f" .pem)"
            done

            ngx_info "looking for configuration snippets in /docker-entrypoint.d/..."
            for f in /docker-entrypoint.d/**/*.json; do
                ngx_info "applying configuration $f"
                curl_put "$f" "config"
            done

            # warn on filetypes we don't know what to do with
            for f in /docker-entrypoint.d/**/*; do
                [ -f "$f" ] || continue
                case "$f" in
                    *.sh | *.json | *.pem) ;;
                    *) ngx_notice "ignoring $f" ;;
                esac
            done

            ngx_info "stopping Unit daemon after initial configuration..."
            # Guard symmetrically with the trap (see config_failed): an empty or
            # missing pidfile must not abort the script under `set -e` and trip
            # the EXIT trap, which would wipe the successfully-configured state.
            [ -f /var/run/unit.pid ] && kill -TERM "$(cat /var/run/unit.pid)" 2>/dev/null || true

            while [ -S /var/run/control.unit.sock ]; do
                ngx_info "waiting for control socket to be removed..."
                sleep 0.1
            done

            ngx_notice "unit initial configuration complete; ready for start up..."
            trap - EXIT
        else
            ngx_notice "/docker-entrypoint.d/ is empty, skipping initial configuration..."
        fi
    fi
fi

exec "$@"
