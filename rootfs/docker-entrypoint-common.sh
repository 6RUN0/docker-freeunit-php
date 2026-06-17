#!/usr/bin/env bash

# Filesystem layout, single-sourced for this file, docker-entrypoint.sh and the
# healthcheck. UNIT_RUNTIME/UNIT_RUNDIR mirror the on-disk identity the installed
# freeunit package was compiled with (binary ${UNIT_RUNTIME}d, /var/lib/<rt>,
# control.<rt>.sock, <rt>.pid, /var/log/<rt>.log — the Dockerfile asserts the
# binary matches at build time); everything below derives from them, so a rebrand
# is a one-line edit here mirrored by the Dockerfile's RUNTIME/RUNDIR ARGs.
# Kept as readonly LITERALS — deliberately NOT env-derived — so the state-dir
# wipe target and the control paths cannot be redirected by untrusted runtime
# env. They are also the defaults for the core functions below; every function
# still takes the path as an argument so a child hook can target a different one.
# ENTRYPOINT_HOOK_DIR in particular must not be env-overridable: the dispatcher
# sources files from it as root before any privilege drop.
readonly UNIT_RUNTIME=freeunit
readonly UNIT_RUNDIR=/var/run
# shellcheck disable=SC2034  # consumed by docker-entrypoint.sh (default launch + dispatch) and the healthcheck
readonly UNIT_BINARY=${UNIT_RUNTIME}d
readonly UNIT_STATE_DIR=/var/lib/${UNIT_RUNTIME}
readonly UNIT_CONTROL_SOCKET=${UNIT_RUNDIR}/control.${UNIT_RUNTIME}.sock
readonly UNIT_PID_FILE=${UNIT_RUNDIR}/${UNIT_RUNTIME}.pid
readonly ENTRYPOINT_CONFIG_DIR=/docker-entrypoint.d
# shellcheck disable=SC2034  # consumed by the dispatcher loop in docker-entrypoint.sh
readonly ENTRYPOINT_HOOK_DIR=/docker-entrypoint-hook.d

# Upper bounds (in 0.1s ticks) for the daemon-readiness and shutdown waits below.
# A freeunitd that forks then dies before binding the control socket (bad config,
# OOM, exec failure), or one that ignores TERM, would otherwise spin these loops
# forever and wedge the container invisibly to restart policies / healthchecks.
# Bounding them turns a silent hang into an observable crash (readiness) or a
# forced SIGKILL (shutdown), so the container makes progress either way.
readonly UNIT_READY_TIMEOUT_TICKS=300 # ~30s to start accepting control requests
readonly UNIT_STOP_TIMEOUT_TICKS=100  # ~10s to release the socket, then SIGKILL

if [ -z "${UNIT_ENTRYPOINT_QUIET_LOGS:-}" ]; then
    exec 3>&2
else
    exec 3>/dev/null
fi

# --- Logging --------------------------------------------------------------
# nginx-style log lines on fd 3. log() takes the level token; the rest are
# thin wrappers. die() logs at err level and exits — the name signals that
# control does not return.

log() {
    local level="$1"
    shift
    printf '%s [%s] %s#%s [entrypoint] #0: %s\n' "$(date +'%Y/%m/%d %H:%M:%S')" "$level" "$$" "$$" "$*" >&3
}

die() {
    log err "$@"
    exit 1
}

log_warn() {
    log warning "$@"
}

log_notice() {
    log notice "$@"
}

log_info() {
    log info "$@"
}

# --- Control API ----------------------------------------------------------

# PUT a file to a control-API endpoint over the control socket.
# Args: <file> <endpoint> [socket]   (e.g. curl_put app.json "config")
curl_put() {
    local file=$1 endpoint=$2 socket=${3:-$UNIT_CONTROL_SOCKET}
    local response status body
    # -w '%{http_code}' appends the 3-digit status (000 on a transport failure)
    # right after the body; a non-zero curl exit means it never reached the socket.
    if ! response=$(curl -s -w '%{http_code}' -X PUT --data-binary "@$file" \
        --unix-socket "$socket" "http://localhost/$endpoint"); then
        die "curl failed to PUT '$file' to '$endpoint'"
    fi
    status=${response: -3}
    body=${response%???}
    # Unit's control API answers 200 today; accept any 2xx so a future endpoint
    # returning 201/202 is not misread as a failure. On success log only the
    # status, not the response body: the body is echoed to stdout (unit.log), and
    # while today it is a terse acknowledgement, unconditionally logging whatever
    # an endpoint returns is a leak waiting to happen. The body is still surfaced
    # on the error path, where it is the diagnostic.
    case "$status" in
        2??)
            log_info "control API accepted '$file' (HTTP $status)"
            ;;
        *)
            die "unexpected HTTP status '$status' while applying '$file'. Body: $body"
            ;;
    esac
}

# --- Filesystem helpers ---------------------------------------------------

# True when DIR contains at least one entry (depth >= 1). A missing DIR counts as
# no content (a fresh container), but an existing-yet-unreadable DIR is an error,
# not "empty": silently treating an EACCES on the state dir as empty would make
# is_first_run re-initialise over a populated state. Args: <dir>
dir_has_content() {
    local dir=${1:?dir_has_content: dir required}
    [ -e "$dir" ] || return 1
    [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] \
        || die "dir_has_content: '$dir' is not a readable directory"
    find "$dir/" -mindepth 1 -print -quit | grep -q .
}

# True on a fresh container, i.e. the state dir holds no persisted config yet
# (initial configuration should run). Boolean — use it in a condition.
# Args: [statedir] (default UNIT_STATE_DIR)
is_first_run() {
    ! dir_has_content "${1:-$UNIT_STATE_DIR}"
}

# --- Unit daemon lifecycle ------------------------------------------------

# Launch freeunitd against the control socket. --pid is explicit so stop_unit kills
# the path freeunitd actually writes, independent of FreeUnit's compile-time default.
# Args: <binary> (freeunitd|freeunitd-debug) [control_socket] [pidfile]
start_unit() {
    local binary=$1 socket=${2:-$UNIT_CONTROL_SOCKET} pidfile=${3:-$UNIT_PID_FILE}
    /usr/sbin/"$binary" --control "unix:$socket" --pid "$pidfile"
}

# Block until the control API actually answers. The socket file appearing does
# not mean freeunitd accepts requests yet; a bare curl would abort under `set -e`
# on a connection-refused blip, so the loop tolerates transient failures. Bounded
# by UNIT_READY_TIMEOUT_TICKS: if freeunitd forked but never opened the socket, die so
# the caller's EXIT trap fires (wipe + retry) instead of hanging forever.
# Args: [control_socket] (default UNIT_CONTROL_SOCKET)
wait_for_control_socket() {
    local socket=${1:-$UNIT_CONTROL_SOCKET} ticks=0
    # --max-time bounds each probe so a socket that accepts but never replies
    # cannot stretch the wall-clock far past the advertised tick budget.
    until curl -fsS --max-time 1 --unix-socket "$socket" http://localhost/ >/dev/null 2>&1; do
        if [ "$ticks" -ge "$UNIT_READY_TIMEOUT_TICKS" ]; then
            die "control socket '$socket' did not accept requests within $((UNIT_READY_TIMEOUT_TICKS / 10))s"
        fi
        log_info "waiting for control socket to accept requests..."
        sleep 0.1
        ticks=$((ticks + 1))
    done
}

# Echo a single, validated pid from PIDFILE (empty if absent/malformed). The read
# is decoupled from its own exit status on purpose: `read` returns non-zero on a
# last line without a trailing newline even though it assigned the value, so the
# tempting `read pid <f && kill $pid` guard would skip the kill for a newline-less
# pidfile. The first line is taken (no word-splitting into multiple targets) and a
# non-numeric value is rejected so a corrupt pidfile cannot become a broad
# `kill -TERM -1`-style signal. Args: <pidfile>
read_pid() {
    local pidfile=$1 pid=""
    [ -f "$pidfile" ] || return 0
    read -r pid <"$pidfile" || true
    case "$pid" in
        '' | *[!0-9]*) return 0 ;;
        *) printf '%s' "$pid" ;;
    esac
}

# Gracefully stop freeunitd (TERM via the pidfile) and wait for it to actually exit.
# A missing/empty/malformed pidfile signals nothing (see read_pid). Bounded by
# UNIT_STOP_TIMEOUT_TICKS: a daemon that ignores TERM is escalated to SIGKILL
# rather than blocking the caller forever. Args: [pidfile] [control_socket]
stop_unit() {
    local pidfile=${1:-$UNIT_PID_FILE} socket=${2:-$UNIT_CONTROL_SOCKET}
    local pid ticks=0
    pid=$(read_pid "$pidfile")
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
    # Wait for the master process to exit, not merely for the control socket to
    # vanish: Unit can unlink the socket part-way through shutdown while the
    # master is still flushing the state dir, and the happy-path caller restarts
    # freeunitd immediately after, racing a half-written state. With a pid, gate on
    # the process; with no pidfile to read, fall back to the socket disappearing.
    while { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } \
        || { [ -z "$pid" ] && [ -S "$socket" ]; }; do
        if [ "$ticks" -ge "$UNIT_STOP_TIMEOUT_TICKS" ]; then
            log_warn "unit did not stop within $((UNIT_STOP_TIMEOUT_TICKS / 10))s; sending SIGKILL"
            [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
            break
        fi
        log_info "waiting for unit to stop..."
        sleep 0.1
        ticks=$((ticks + 1))
    done
}

# --- /docker-entrypoint.d appliers ----------------------------------------
# Each iterates DIR (default ENTRYPOINT_CONFIG_DIR) lexically and recursively.
# run_entrypoint_scripts is safe without a running freeunitd; apply_certificates and
# apply_config PUT over the control socket, so they need a ready daemon.
# Each re-sets nullglob/globstar locally (the dispatcher already sets them
# globally) so a child hook can call any applier standalone; do not "clean up"
# the seemingly redundant shopt.

# Execute every *.sh hook (via its own shebang, so it needs the execute bit).
# A bind-mounted script checked out without +x would otherwise fail with an
# opaque exit 126 that trips the first-run EXIT trap (wipe + restart loop); fail
# with an actionable message instead.
#
# Ownership is deliberately NOT enforced here (unlike the hook dir): this dir is
# the operator-facing config drop, routinely bind-mounted from the host where the
# files belong to the host uid, not root (the smoke test does exactly that). The
# trust boundary is "the operator controls what they mount"; harden it by not
# mounting /docker-entrypoint.d from a volume that an unprivileged principal can
# write. Args: [dir]
run_entrypoint_scripts() {
    local dir=${1:-$ENTRYPOINT_CONFIG_DIR}
    shopt -s nullglob globstar
    for f in "$dir"/**/*.sh; do
        if [ ! -x "$f" ]; then
            die "entrypoint script is not executable: $f (chmod +x, or mount it with the execute bit)"
        fi
        log_info "launching $f"
        "$f" || die "entrypoint script failed (exit $?): $f"
    done
}

# Upload every *.pem as a certificate bundle named after the file. The basename
# becomes a control-API path segment, so it is validated to a safe charset: an
# unencoded name with '/', '..' or other URL-significant characters could
# retarget the PUT at a different endpoint (e.g. config). Args: [dir]
apply_certificates() {
    local dir=${1:-$ENTRYPOINT_CONFIG_DIR}
    shopt -s nullglob globstar
    local f name
    for f in "$dir"/**/*.pem; do
        name=$(basename "$f" .pem)
        case "$name" in
            '' | .* | *[!A-Za-z0-9._-]*)
                die "unsafe certificate bundle name '$name' (from $f); use [A-Za-z0-9._-]" ;;
        esac
        log_info "uploading certificates bundle: $f"
        curl_put "$f" "certificates/$name"
    done
}

# PUT every *.json to the config endpoint. Args: [dir]
# Unit's PUT /config REPLACES the whole configuration, so multiple snippets do
# not merge: only the lexically-last file survives. Warn loudly in that case so a
# user expecting 10-listeners.json + 20-routes.json to combine is not surprised.
apply_config() {
    local dir=${1:-$ENTRYPOINT_CONFIG_DIR}
    shopt -s nullglob globstar
    local -a config_files=("$dir"/**/*.json)
    if [ "${#config_files[@]}" -gt 1 ]; then
        log_warn "multiple *.json in $dir; PUT /config replaces the whole config, so only the last (${config_files[-1]##*/}) takes effect — ship one combined file"
    fi
    local f
    for f in "${config_files[@]}"; do
        log_info "applying configuration $f"
        curl_put "$f" "config"
    done
}

# --- Privilege drop -------------------------------------------------------

# Replace the current process with COMMAND running as <user>:<group>. Uses
# setpriv (util-linux) — gosu/su-exec are intentionally not installed; setpriv
# is the in-image equivalent (no fork, exec-replaces, no PAM). --init-groups
# initialises the user's supplementary groups (resetting any inherited from
# root), like a login shell would. --no-new-privs makes the drop irreversible in
# the image itself: a setuid binary in the image cannot regain privileges even if
# the operator forgot `docker run --security-opt=no-new-privileges`.
# Args: <user> <group> <command> [args...]
exec_as_user() {
    local user=$1 group=$2
    shift 2
    exec setpriv --reuid "$user" --regid "$group" --init-groups --no-new-privs "$@"
}

# --- Trust guards ---------------------------------------------------------

# Refuse a file that will be run or sourced with root privileges if a non-root
# principal could have authored it: owned by a non-root user, or group/world
# writable. Used to guard the hook dir, whose files the dispatcher sources into
# the root entrypoint shell before any privilege drop. A file COPYed into the
# image (root:root, not world-writable) passes; one that an unprivileged process
# could rewrite is rejected before it can execute as root. Args: <file>
assert_safe_root_file() {
    local file=$1
    if [ -n "$(find "$file" -maxdepth 0 \( ! -user 0 -o -perm -0002 -o -perm -0020 \) 2>/dev/null)" ]; then
        die "refusing to use entrypoint file with unsafe ownership/permissions (must be root-owned and not group/world-writable): $file"
    fi
    return 0
}

# --- Command dispatch (for the entrypoint and child launch modes) ---------

# If a hook defined a function handle_<cmd>, invoke it: it owns the launch and
# MUST exec the final process. Reaching the end means it returned (or exited
# non-zero) instead of exec'ing — a contract violation, so die loudly rather than
# let the caller fall through to `exec "$@"` and double-run the command. A
# non-zero return is handled explicitly because, under the caller's `set -e`, it
# would otherwise abort the process before the diagnostic. No-op (returns 0) when
# no handler matches, so the caller proceeds with its default launch path.
# Args: <cmd> [args...]
dispatch_handler() {
    [ -n "${1:-}" ] || return 0
    declare -F "handle_$1" >/dev/null || return 0
    "handle_$1" "$@" \
        || die "entrypoint hook handle_$1 exited $? without exec; a handler must exec the final process"
    die "entrypoint hook handle_$1 returned without exec; a handler must exec the final process"
}

# --- Application user provisioning ----------------------------------------

# Idempotently provision a group + user, and optionally a home/app dir. A child
# image's hook can call this to create a different application user. An existing
# group/user keeps its own GID/UID (the core freeunit package's postinst already
# created 'freeunit' with a system-range UID), so a requested id is ignored then —
# logged, not failed.
#
# DIR must be a container-owned path: with chown=yes its ownership is rewritten,
# so pointing it at a host bind-mount rewrites host files. The chown uses -xdev
# to stop at filesystem boundaries, so nested mounts under DIR are not traversed.
#
# Args: <user> <uid> <group> <gid> [dir] [chown:yes|no] (dir/chown optional)
setup_user() {
    local user=$1 uid=$2 group=$3 gid=$4 dir=${5:-} chown=${6:-no}

    case "$uid$gid" in
        *[!0-9]*) die "setup_user: uid/gid must be numeric (got '$uid' / '$gid')" ;;
    esac

    if getent group "$group" >/dev/null; then
        log_info "app group '$group' already exists; keeping its GID, ignoring gid='$gid'"
    else
        log_info "create app group: '$group' (gid $gid)"
        # The name is free but the gid may not be (a customised base image may
        # already use 1000); without this guard groupadd's failure aborts startup
        # under set -e with no hint at the cause.
        if ! groupadd "$group" -g "$gid"; then
            die "failed to create app group '$group' (gid $gid already in use? pick a free APPLICATION_GID or pre-create the group)"
        fi
    fi

    if getent passwd "$user" >/dev/null; then
        log_info "app user '$user' already exists; keeping its UID, ignoring uid='$uid'"
    else
        log_info "create app user: '$user' (uid $uid)"
        if ! useradd -M -s /bin/bash -g "$group" -u "$uid" "$user"; then
            die "failed to create app user '$user' (uid $uid already in use? pick a free APPLICATION_UID or pre-create the user)"
        fi
    fi

    [ -n "$dir" ] || return 0

    if [ ! -d "$dir" ]; then
        log_info "create app dir: '$dir'"
        mkdir -p "$dir"
    fi
    if ! usermod --home "$dir" "$user" >/dev/null 2>&1; then
        log_warn "failed to set home of '$user' to '$dir'"
    fi
    if [ "$chown" = "yes" ]; then
        find "$dir" -xdev \! -user "$user" -exec chown "$user":"$group" '{}' +
    fi
}

# --- First-run orchestration ----------------------------------------------

# EXIT trap for unit_initial_configuration: wipe the half-written state if the
# first-run configuration fails, so the next start re-runs initialization
# cleanly instead of booting a partial config (a non-empty UNIT_STATE_DIR makes
# unit_initial_configuration skip initialization). Like unit_initial_configuration
# it operates on the default UNIT_* paths only (an EXIT trap cannot take
# arguments); a child launch mode that wants the first-run routine on different
# paths must compose start_unit/stop_unit/the appliers itself rather than reuse
# this pair.
unit_config_failed() {
    local exit_code=$?
    [ "$exit_code" -eq 0 ] && return 0
    log_notice "initial configuration failed (exit $exit_code); wiping $UNIT_STATE_DIR so it is retried on next start"
    # TERM, then a bounded wait for the process to actually exit before the wipe,
    # so `find -delete` does not race a freeunitd still writing to the state dir. The
    # wait is on the pid (not the control socket): on the failure path freeunitd may be
    # wedged, and blocking on a socket that never disappears would hang the EXIT
    # trap. Bounded by UNIT_STOP_TIMEOUT_TICKS, then SIGKILL, so the trap always
    # makes progress.
    local pid ticks=0
    pid=$(read_pid "$UNIT_PID_FILE")
    # The master writes its pidfile asynchronously after forking, so if the
    # failure was wait_for_control_socket timing out on a slow/early-dying start,
    # the pid may not be readable yet. Briefly wait for it to appear so we TERM the
    # real master instead of letting the wipe race a daemon still coming up.
    if [ -z "$pid" ]; then
        while [ "$ticks" -lt "$UNIT_STOP_TIMEOUT_TICKS" ]; do
            sleep 0.1
            ticks=$((ticks + 1))
            pid=$(read_pid "$UNIT_PID_FILE")
            [ -n "$pid" ] && break
        done
        ticks=0
    fi
    if [ -n "$pid" ]; then
        kill -TERM "$pid" 2>/dev/null || true
        while kill -0 "$pid" 2>/dev/null; do
            if [ "$ticks" -ge "$UNIT_STOP_TIMEOUT_TICKS" ]; then
                kill -KILL "$pid" 2>/dev/null || true
                break
            fi
            sleep 0.1
            ticks=$((ticks + 1))
        done
    fi
    # -xdev mirrors setup_user's chown: stop at filesystem boundaries so a host
    # volume bind-mounted *inside* the state dir is never wiped on the host.
    find "$UNIT_STATE_DIR" -xdev -mindepth 1 -delete 2>/dev/null || true
}

# The full first-run routine, composed from the core functions above so a child
# launch mode can call it or reuse the pieces: on a fresh container with config
# present, launch freeunitd, apply *.sh/*.pem/*.json, then stop it so the real start
# boots a populated state. It (and its EXIT trap unit_config_failed) work on the
# default UNIT_* paths only; a child that needs different state/socket/pid paths
# should compose the pieces directly rather than call this. Args: <binary> (the
# freeunitd binary name).
unit_initial_configuration() {
    local binary=$1

    if ! is_first_run; then
        log_notice "$UNIT_STATE_DIR is not empty, skipping initial configuration..."
        return 0
    fi
    if ! dir_has_content "$ENTRYPOINT_CONFIG_DIR"; then
        log_notice "$ENTRYPOINT_CONFIG_DIR is empty, skipping initial configuration..."
        return 0
    fi

    trap unit_config_failed EXIT

    log_info "$ENTRYPOINT_CONFIG_DIR is not empty, launching Unit daemon to perform initial configuration..."
    start_unit "$binary"
    wait_for_control_socket

    log_info "looking for shell scripts in $ENTRYPOINT_CONFIG_DIR..."
    run_entrypoint_scripts
    log_info "looking for certificate bundles in $ENTRYPOINT_CONFIG_DIR..."
    apply_certificates
    log_info "looking for configuration snippets in $ENTRYPOINT_CONFIG_DIR..."
    apply_config

    # warn on filetypes we don't know what to do with
    shopt -s nullglob globstar
    for f in "$ENTRYPOINT_CONFIG_DIR"/**/*; do
        [ -f "$f" ] || continue
        case "$f" in
            *.sh | *.json | *.pem) ;;
            *) log_notice "ignoring $f" ;;
        esac
    done

    log_info "stopping Unit daemon after initial configuration..."
    stop_unit

    log_notice "unit initial configuration complete; ready for start up..."
    trap - EXIT
}

# --- Default application user (base image behavior) -----------------------
# Provision the default 'freeunit' app user from the APPLICATION_* env (it maps
# to the system freeunit:freeunit the package's postinst already created, so the
# requested 1000 is ignored when that user exists). A child hook can call
# setup_user again with other arguments for a different user. Guarded so a
# consumer that sources this lib only for the constants/functions (the
# healthcheck) skips the side effect with UNIT_LIB_NO_PROVISION=1.
if [ -z "${UNIT_LIB_NO_PROVISION:-}" ]; then
    APPLICATION_USER=${APPLICATION_USER:="freeunit"}
    APPLICATION_UID=${APPLICATION_UID:="1000"}
    APPLICATION_GROUP=${APPLICATION_GROUP:="freeunit"}
    APPLICATION_GID=${APPLICATION_GID:="1000"}
    APPLICATION_CHOWN=${APPLICATION_CHOWN:="yes"}

    setup_user "$APPLICATION_USER" "$APPLICATION_UID" "$APPLICATION_GROUP" "$APPLICATION_GID" \
        "${APPLICATION_DIR:-}" "$APPLICATION_CHOWN"
fi
