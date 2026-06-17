#!/usr/bin/env bash

# Container HEALTHCHECK probe. App listener ports are configured at runtime (so
# there is no fixed port to probe), but a responsive control API proves the
# daemon and the embedded PHP module are up. Runs as root (the image default),
# which owns the 0600 control socket, so it works even under --cap-drop=ALL.
#
# It is a script (not an inline HEALTHCHECK CMD) so the control-socket path stays
# single-sourced from docker-entrypoint-common.sh (UNIT_CONTROL_SOCKET) instead
# of being duplicated in the Dockerfile: an exec-form CMD cannot expand a build
# ARG/ENV. The library is sourced with UNIT_LIB_NO_PROVISION=1 so it yields only
# the constants — the default-app-user provisioning at its tail (a root-side
# effect: getent/useradd and possibly a recursive chown) must not run on every
# probe.
set -eu

UNIT_LIB_NO_PROVISION=1 . /docker-entrypoint-common.sh

exec curl -fsS -o /dev/null --unix-socket "$UNIT_CONTROL_SOCKET" http://localhost/
