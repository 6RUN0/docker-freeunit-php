#!/bin/sh

# Container HEALTHCHECK probe. App listener ports are configured at runtime (so
# there is no fixed port to probe), but a responsive control API proves the
# daemon and the embedded PHP module are up. The 0600 control socket belongs to
# the uid the daemon runs as. Docker runs the probe as the container user: after
# a root start (the entrypoint dropped to 65532) that is root, which without
# CAP_DAC_OVERRIDE cannot open the socket, so a root probe switches to the
# socket's owner when it can (CAP_SETUID/CAP_SETGID, required by that start
# anyway). `stat -c` is supported by GNU coreutils and busybox.
#
# It is a script (not an inline HEALTHCHECK CMD) so the control-socket path stays
# single-sourced from docker-entrypoint-common.sh (UNIT_CONTROL_SOCKET) instead
# of being duplicated in the Dockerfile: an exec-form CMD cannot expand a build
# ARG/ENV. Sourcing the library has no side effects; this script does not call
# drop_root_or_die. Portable POSIX sh.
set -eu

. /docker-entrypoint-common.sh

if [ "$(id -u)" = 0 ]; then
    _hc_owner=$(stat -c '%u:%g' "$UNIT_CONTROL_SOCKET" 2>/dev/null || true)
    _hc_uid=${_hc_owner%:*}
    _hc_gid=${_hc_owner#*:}
    if [ -n "$_hc_owner" ] && [ "$_hc_uid" != 0 ] \
        && setpriv --reuid="$_hc_uid" --regid="$_hc_gid" --clear-groups true 2>/dev/null; then
        exec setpriv --reuid="$_hc_uid" --regid="$_hc_gid" --clear-groups \
            curl -fsS -o /dev/null --unix-socket "$UNIT_CONTROL_SOCKET" http://localhost/
    fi
fi
exec curl -fsS -o /dev/null --unix-socket "$UNIT_CONTROL_SOCKET" http://localhost/
