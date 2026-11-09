#!/bin/sh
#
# Core library of the entrypoint, sourced (`.`) by docker-entrypoint.sh, the
# healthcheck and the hooks in /docker-entrypoint-hook.d. Portable POSIX sh: it
# runs under /bin/sh of the image (dash) and must keep working under any POSIX
# shell (busybox ash included), so no bash extensions and no GNU-only options.
#
# POSIX sh has no `local`: a function's variables are globals. Every variable a
# library function sets is prefixed `_ep_<function>_` so it cannot shadow a
# variable of a hook or of the environment; hooks use their own prefix (see the
# hook contract in docker-entrypoint.sh). Positional parameters are the only
# per-call state and are used where a value must survive a nested call.

# Filesystem layout, single-sourced for this file, docker-entrypoint.sh and the
# healthcheck. UNIT_RUNTIME/UNIT_RUNDIR mirror the on-disk identity the installed
# freeunit package was compiled with (binary ${UNIT_RUNTIME}d, control.<rt>.sock,
# <rt>.pid, /var/log/<rt>.log - the Dockerfile asserts the binary matches at build
# time). The state dir is not the compiled /var/lib/<rt>: the daemon runs as the
# unprivileged container user and keeps its state next to the socket in /run (a
# small tmpfs under read_only), so every launch passes --statedir and --tmpdir.
# Kept as readonly LITERALS - deliberately NOT env-derived - so the state-dir wipe
# target and the control paths cannot be redirected by untrusted runtime env.
# They are also the defaults for the core functions below; every function still
# takes the path as an argument so a child hook can target a different one.
# ENTRYPOINT_HOOK_DIR in particular must not be env-overridable: the dispatcher
# sources files from it into the entrypoint shell. The values contain no
# whitespace or glob characters: build_unit_launch_args relies on that.
readonly UNIT_RUNTIME=freeunit
readonly UNIT_RUNDIR=/var/run
# shellcheck disable=SC2034  # consumed by docker-entrypoint.sh (default launch + dispatch) and the healthcheck
readonly UNIT_BINARY=${UNIT_RUNTIME}d
readonly UNIT_STATE_DIR=/run/${UNIT_RUNTIME}
readonly UNIT_TMP_DIR=/tmp
readonly UNIT_CONTROL_SOCKET=${UNIT_RUNDIR}/control.${UNIT_RUNTIME}.sock
readonly UNIT_PID_FILE=${UNIT_RUNDIR}/${UNIT_RUNTIME}.pid
readonly ENTRYPOINT_CONFIG_DIR=/docker-entrypoint.d
# Fragments a /docker-entrypoint.d/*.sh renders at start-up (Unit config, TLS
# bundles) go here, not into the read-only image: *.pem and *.json from this dir
# are applied after those of ENTRYPOINT_CONFIG_DIR, *.sh are not executed.
# Exported so the scripts find it without hard-coding the path.
readonly ENTRYPOINT_GENERATED_DIR=/run/docker-entrypoint.d
export ENTRYPOINT_GENERATED_DIR
# shellcheck disable=SC2034  # consumed by the dispatcher loop in docker-entrypoint.sh
readonly ENTRYPOINT_HOOK_DIR=/docker-entrypoint-hook.d

# The image user (distroless 'nonroot'), created by the Dockerfile, which asserts
# its passwd entry matches these values. drop_root_or_die drops a root start to
# exactly this uid:gid.
readonly UNIT_NONROOT_UID=65532
readonly UNIT_NONROOT_GID=65532
readonly UNIT_NONROOT_HOME=/home/nonroot

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
# thin wrappers. die() logs at err level and exits - the name signals that
# control does not return. Called inside $(...) it ends only that subshell.

log() {
    _ep_log_level=$1
    shift
    printf '%s [%s] %s#%s [entrypoint] #0: %s\n' "$(date +'%Y/%m/%d %H:%M:%S')" "$_ep_log_level" "$$" "$$" "$*" >&3
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
    _ep_cp_file=$1
    _ep_cp_endpoint=$2
    _ep_cp_socket=${3:-$UNIT_CONTROL_SOCKET}
    # -w '%{http_code}' appends the 3-digit status (000 on a transport failure)
    # right after the body; a non-zero curl exit means it never reached the socket.
    if ! _ep_cp_response=$(curl -s -w '%{http_code}' -X PUT --data-binary "@$_ep_cp_file" \
        --unix-socket "$_ep_cp_socket" "http://localhost/$_ep_cp_endpoint"); then
        die "curl failed to PUT '$_ep_cp_file' to '$_ep_cp_endpoint'"
    fi
    _ep_cp_body=${_ep_cp_response%???}
    _ep_cp_status=${_ep_cp_response#"$_ep_cp_body"}
    # Unit's control API answers 200 today; accept any 2xx so a future endpoint
    # returning 201/202 is not misread as a failure. On success log only the
    # status, not the response body: the body is echoed to stdout (unit.log), and
    # while today it is a terse acknowledgement, unconditionally logging whatever
    # an endpoint returns is a leak waiting to happen. The body is still surfaced
    # on the error path, where it is the diagnostic.
    case "$_ep_cp_status" in
        2??)
            log_info "control API accepted '$_ep_cp_file' (HTTP $_ep_cp_status)"
            ;;
        *)
            die "unexpected HTTP status '$_ep_cp_status' while applying '$_ep_cp_file'. Body: $_ep_cp_body"
            ;;
    esac
}

# --- Filesystem helpers ---------------------------------------------------

# True when DIR contains at least one entry (depth >= 1). A missing DIR counts as
# no content (a fresh container), but an existing-yet-unreadable DIR is an error,
# not "empty": silently treating an EACCES on the state dir as empty would make
# is_first_run re-initialise over a populated state. Args: <dir>
dir_has_content() {
    _ep_dhc_dir=${1:?dir_has_content: dir required}
    [ -e "$_ep_dhc_dir" ] || return 1
    [ -d "$_ep_dhc_dir" ] && [ -r "$_ep_dhc_dir" ] && [ -x "$_ep_dhc_dir" ] \
        || die "dir_has_content: '$_ep_dhc_dir' is not a readable directory"
    [ -n "$(find "$_ep_dhc_dir/" -mindepth 1 -print -quit)" ]
}

# True on a fresh container, i.e. the state dir holds no persisted config yet
# (initial configuration should run). Boolean - use it in a condition.
# Args: [statedir] (default UNIT_STATE_DIR)
is_first_run() {
    ! dir_has_content "${1:-$UNIT_STATE_DIR}"
}

# Print the files of DIR whose name ends in SUFFIX, one per line, recursively and
# in byte order (LC_ALL=C), skipping hidden files and directories (a Kubernetes
# ConfigMap mount keeps its real files under ..data and links them at the top).
# Symlinks are listed whatever they point at; the appliers refuse one that is
# not a regular file (assert_regular_file). A missing DIR prints nothing. An
# unreadable subdirectory dies instead of silently dropping its files: find's
# status is checked before the sort, not lost in a pipeline. Called in $(...),
# so the caller adds `|| exit 1` (the die message is already logged). A newline
# in a file name splits it in two: such names are not supported.
# Args: <dir> <suffix>
list_entrypoint_files() {
    [ -d "$1" ] || return 0
    _ep_lef_found=$(find "$1" -mindepth 1 -name '.*' -prune -o \( -type f -o -type l \) -name "*$2" -print) \
        || die "cannot list $1 (an unreadable subdirectory?); its files would be skipped"
    [ -n "$_ep_lef_found" ] || return 0
    printf '%s\n' "$_ep_lef_found" | LC_ALL=C sort
}

# Die unless FILE is a regular file or a symlink to one: a dangling link or a
# link to a directory with a *.sh/*.pem/*.json name would otherwise fail later
# with a misleading "not executable" or a curl error. Args: <file>
assert_regular_file() {
    [ -f "$1" ] || die "entrypoint file is not a regular file (a dangling symlink or a link to a directory?): $1"
}

# --- Unit daemon lifecycle ------------------------------------------------

# Launch freeunitd against the control socket. --pid is explicit so stop_unit kills
# the path freeunitd actually writes; --statedir and --tmpdir are explicit because
# the compiled defaults (/var/lib/<rt>, root-owned) are not writable for the
# unprivileged container user.
# Args: <binary> (freeunitd|freeunitd-debug) [control_socket] [pidfile] [statedir] [tmpdir]
start_unit() {
    /usr/sbin/"$1" --control "unix:${2:-$UNIT_CONTROL_SOCKET}" --pid "${3:-$UNIT_PID_FILE}" \
        --statedir "${4:-$UNIT_STATE_DIR}" --tmpdir "${5:-$UNIT_TMP_DIR}"
}

# Block until the control API actually answers. The socket file appearing does
# not mean freeunitd accepts requests yet; a bare curl would abort under `set -e`
# on a connection-refused blip, so the loop tolerates transient failures. Bounded
# by UNIT_READY_TIMEOUT_TICKS: if freeunitd forked but never opened the socket, die so
# the caller's EXIT trap fires (wipe + retry) instead of hanging forever.
# Args: [control_socket] (default UNIT_CONTROL_SOCKET)
wait_for_control_socket() {
    _ep_wfcs_socket=${1:-$UNIT_CONTROL_SOCKET}
    _ep_wfcs_ticks=0
    # --max-time bounds each probe so a socket that accepts but never replies
    # cannot stretch the wall-clock far past the advertised tick budget.
    until curl -fsS --max-time 1 --unix-socket "$_ep_wfcs_socket" http://localhost/ >/dev/null 2>&1; do
        if [ "$_ep_wfcs_ticks" -ge "$UNIT_READY_TIMEOUT_TICKS" ]; then
            die "control socket '$_ep_wfcs_socket' did not accept requests within $((UNIT_READY_TIMEOUT_TICKS / 10))s"
        fi
        log_info "waiting for control socket to accept requests..."
        sleep 0.1
        _ep_wfcs_ticks=$((_ep_wfcs_ticks + 1))
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
    _ep_rp_pid=
    [ -f "$1" ] || return 0
    read -r _ep_rp_pid <"$1" || true
    case "$_ep_rp_pid" in
        '' | *[!0-9]*) return 0 ;;
        *) printf '%s' "$_ep_rp_pid" ;;
    esac
}

# Gracefully stop freeunitd (TERM via the pidfile) and wait for it to actually exit.
# A missing/empty/malformed pidfile signals nothing (see read_pid). Bounded by
# UNIT_STOP_TIMEOUT_TICKS: a daemon that ignores TERM is escalated to SIGKILL
# rather than blocking the caller forever. Args: [pidfile] [control_socket]
stop_unit() {
    _ep_su_socket=${2:-$UNIT_CONTROL_SOCKET}
    _ep_su_ticks=0
    _ep_su_pid=$(read_pid "${1:-$UNIT_PID_FILE}")
    if [ -n "$_ep_su_pid" ]; then
        kill -TERM "$_ep_su_pid" 2>/dev/null || true
    fi
    # Wait for the master process to exit, not merely for the control socket to
    # vanish: Unit can unlink the socket part-way through shutdown while the
    # master is still flushing the state dir, and the happy-path caller restarts
    # freeunitd immediately after, racing a half-written state. With a pid, gate on
    # the process; with no pidfile to read, fall back to the socket disappearing.
    while { [ -n "$_ep_su_pid" ] && kill -0 "$_ep_su_pid" 2>/dev/null; } \
        || { [ -z "$_ep_su_pid" ] && [ -S "$_ep_su_socket" ]; }; do
        if [ "$_ep_su_ticks" -ge "$UNIT_STOP_TIMEOUT_TICKS" ]; then
            log_warn "unit did not stop within $((UNIT_STOP_TIMEOUT_TICKS / 10))s; sending SIGKILL"
            if [ -n "$_ep_su_pid" ]; then
                kill -KILL "$_ep_su_pid" 2>/dev/null || true
            fi
            break
        fi
        log_info "waiting for unit to stop..."
        sleep 0.1
        _ep_su_ticks=$((_ep_su_ticks + 1))
    done
}

# --- /docker-entrypoint.d appliers ----------------------------------------
# Each iterates DIR (default ENTRYPOINT_CONFIG_DIR) recursively in byte order
# (list_entrypoint_files). run_entrypoint_scripts is safe without a running
# freeunitd; apply_certificates and apply_config PUT over the control socket, so
# they need a ready daemon. The file list is read from fd 4 (a here-document), so
# the loop runs in the current shell (die ends the entrypoint, not a pipeline
# subshell) and the scripts keep the container's stdin.

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
    _ep_res_list=$(list_entrypoint_files "${1:-$ENTRYPOINT_CONFIG_DIR}" .sh) || exit 1
    while IFS= read -r _ep_res_file <&4; do
        [ -n "$_ep_res_file" ] || continue
        assert_regular_file "$_ep_res_file"
        if [ ! -x "$_ep_res_file" ]; then
            die "entrypoint script is not executable: $_ep_res_file (chmod +x, or mount it with the execute bit)"
        fi
        log_info "launching $_ep_res_file"
        "$_ep_res_file" 4<&- || die "entrypoint script failed (exit $?): $_ep_res_file"
    done 4<<EOF
$_ep_res_list
EOF
}

# Upload every *.pem as a certificate bundle named after the file. The basename
# becomes a control-API path segment, so it is validated to a safe charset: an
# unencoded name with '/', '..' or other URL-significant characters could
# retarget the PUT at a different endpoint (e.g. config). Args: [dir]
apply_certificates() {
    _ep_ac_list=$(list_entrypoint_files "${1:-$ENTRYPOINT_CONFIG_DIR}" .pem) || exit 1
    while IFS= read -r _ep_ac_file <&4; do
        [ -n "$_ep_ac_file" ] || continue
        assert_regular_file "$_ep_ac_file"
        _ep_ac_name=$(basename "$_ep_ac_file" .pem)
        case "$_ep_ac_name" in
            '' | .* | *[!A-Za-z0-9._-]*)
                die "unsafe certificate bundle name '$_ep_ac_name' (from $_ep_ac_file); use [A-Za-z0-9._-]" ;;
        esac
        log_info "uploading certificates bundle: $_ep_ac_file"
        curl_put "$_ep_ac_file" "certificates/$_ep_ac_name"
    done 4<<EOF
$_ep_ac_list
EOF
}

# PUT every *.json to the config endpoint. Args: [dir]
# Unit's PUT /config REPLACES the whole configuration, so multiple snippets do
# not merge: only the last file survives. Warn loudly in that case so a user
# expecting 10-listeners.json + 20-routes.json to combine is not surprised.
apply_config() {
    _ep_acf_dir=${1:-$ENTRYPOINT_CONFIG_DIR}
    _ep_acf_list=$(list_entrypoint_files "$_ep_acf_dir" .json) || exit 1
    case "$_ep_acf_list" in
        *"
"*)
            log_warn "multiple *.json in $_ep_acf_dir; PUT /config replaces the whole config, so only the last (${_ep_acf_list##*/}) takes effect - ship one combined file"
            ;;
    esac
    while IFS= read -r _ep_acf_file <&4; do
        [ -n "$_ep_acf_file" ] || continue
        assert_regular_file "$_ep_acf_file"
        log_info "applying configuration $_ep_acf_file"
        curl_put "$_ep_acf_file" "config"
    done 4<<EOF
$_ep_acf_list
EOF
}

# --- Root guard and runtime dirs ------------------------------------------

# Change the owner of the stdio descriptors that are a fifo, a socket or a
# terminal to the image user. runc hands stdio to the container user only when
# one is configured (--user / USER); after a root start the fifos stay root 0600
# and the dropped process could not reopen /dev/stdout, the target of the Unit
# log symlink. /dev/null and regular files are left alone. Needs CAP_CHOWN.
# The paths go through /proc/$$ (this shell): /proc/self in the argument of the
# external chown would resolve to chown's own descriptors. No redirection may
# touch stdio around these calls, chown's own included: under the dash of
# Debian trixie a `2>/dev/null` on chown made /proc/$$/fd/2 resolve to
# /dev/null, which got chowned instead of stderr (the smoke test catches it). A
# chown error therefore reaches stderr; it precedes the die message.
chown_stdio_to_nonroot() {
    for _ep_csn_fd in 0 1 2; do
        if [ -p "/proc/$$/fd/$_ep_csn_fd" ] || [ -S "/proc/$$/fd/$_ep_csn_fd" ] || [ -t "$_ep_csn_fd" ]; then
            chown "$UNIT_NONROOT_UID:$UNIT_NONROOT_GID" "/proc/$$/fd/$_ep_csn_fd" || return 1
        fi
    done
}

# True when the effective capability set of this shell holds capability
# number <bit> (linux/capability.h: CAP_KILL is 5). CapEff is 64-bit hex; shell
# arithmetic is at least signed 64-bit in dash and busybox ash, and the top
# capability bit (40) is far below the sign bit. Args: <bit>
has_effective_cap() {
    while read -r _ep_hec_key _ep_hec_value; do
        if [ "$_ep_hec_key" = CapEff: ]; then
            [ $(((0x$_ep_hec_value >> $1) & 1)) -eq 1 ]
            return
        fi
    done <"/proc/$$/status"
    return 1
}

# Refuse to run with root privileges. A process with group 0 among its groups
# but a non-zero uid dies: it cannot drop the group without CAP_SETGID, and group
# 0 opens every root file with g+w. A root start is a fallback, not the
# recommended mode: if CAP_SETUID/CAP_SETGID/CAP_CHOWN/CAP_KILL are available,
# the stdio is handed over and the entrypoint re-execs itself (args: "$0" "$@")
# as UNIT_NONROOT_UID:UNIT_NONROOT_GID with no supplementary groups and
# no_new_privs; otherwise it dies. PID 1 (tini) stays root in that mode with the
# container's capabilities; it only forwards signals and reaps zombies, and
# without CAP_KILL it cannot signal the 65532 processes, so `docker stop` would
# end in SIGKILL. HOME is set explicitly: Docker set root's HOME, and setpriv
# --reset-env would drop the caller's environment. The library does not call
# this on source: the healthcheck sources it too and must not exec.
# Args: <entrypoint> [args...]
drop_root_or_die() {
    _ep_drod_uid=$(id -u)
    _ep_drod_root_group=
    for _ep_drod_group in $(id -g) $(id -G); do
        if [ "$_ep_drod_group" = 0 ]; then
            _ep_drod_root_group=1
        fi
    done
    if [ "$_ep_drod_uid" != 0 ]; then
        if [ -z "$_ep_drod_root_group" ]; then
            return 0
        fi
        die "running as uid $_ep_drod_uid with group 0 among its groups; run with a non-root group (the image default is $UNIT_NONROOT_UID:$UNIT_NONROOT_GID)"
    fi
    if ! has_effective_cap 5 \
        || ! setpriv --reuid="$UNIT_NONROOT_UID" --regid="$UNIT_NONROOT_GID" --clear-groups --no-new-privs true 2>/dev/null \
        || ! chown_stdio_to_nonroot; then
        die "started as root without CAP_SETUID/CAP_SETGID/CAP_CHOWN/CAP_KILL; run as a non-root user (the image default is $UNIT_NONROOT_UID:$UNIT_NONROOT_GID), do not override user"
    fi
    log_warn "started as root; dropping to $UNIT_NONROOT_UID:$UNIT_NONROOT_GID (PID 1 stays root); run as a non-root user instead"
    HOME=$UNIT_NONROOT_HOME exec setpriv --reuid="$UNIT_NONROOT_UID" --regid="$UNIT_NONROOT_GID" \
        --clear-groups --no-new-privs "$@"
}

# Create the state and generated dirs and check that every path the daemon and
# the PHP workers write to is writable by the current user, so a missing tmpfs or
# bind mount fails here with a hint instead of as an EROFS/EACCES deep in Unit.
# The check is on writability, not on a uid: any non-root uid works when the
# mounts belong to it. HOME is not checked: ssh, composer and drush work with a
# read-only HOME; an application that writes there mounts it.
prepare_runtime_dirs() {
    _ep_prd_hint="mount a tmpfs at /run owned by the container user (e.g. --tmpfs /run:uid=$(id -u),gid=$(id -g),mode=0700)"
    mkdir -p "$UNIT_STATE_DIR" "$ENTRYPOINT_GENERATED_DIR" 2>/dev/null \
        || die "cannot create $UNIT_STATE_DIR and $ENTRYPOINT_GENERATED_DIR as uid $(id -u); $_ep_prd_hint"
    for _ep_prd_dir in "$UNIT_RUNDIR" "$UNIT_STATE_DIR" "$ENTRYPOINT_GENERATED_DIR"; do
        [ -d "$_ep_prd_dir" ] && [ -w "$_ep_prd_dir" ] && [ -x "$_ep_prd_dir" ] \
            || die "$_ep_prd_dir is not writable for uid $(id -u); $_ep_prd_hint"
    done
    [ -d "$UNIT_TMP_DIR" ] && [ -w "$UNIT_TMP_DIR" ] && [ -x "$UNIT_TMP_DIR" ] \
        || die "$UNIT_TMP_DIR is not writable for uid $(id -u); request bodies and PHP uploads go there: bind-mount a host dir owned by the container user (or a tmpfs with a size)"
}

# Print the entrypoint's value of a launch flag (--control, --pid, --statedir,
# --tmpdir); nothing for any other argument. Args: <flag>
unit_launch_flag_value() {
    case "$1" in
        --control) printf '%s' "unix:$UNIT_CONTROL_SOCKET" ;;
        --pid) printf '%s' "$UNIT_PID_FILE" ;;
        --statedir) printf '%s' "$UNIT_STATE_DIR" ;;
        --tmpdir) printf '%s' "$UNIT_TMP_DIR" ;;
    esac
}

# Check an explicit freeunitd/freeunitd-debug command line against the launch
# flags the entrypoint relies on: initial configuration writes into
# UNIT_STATE_DIR over UNIT_CONTROL_SOCKET, so the daemon started afterwards must
# use the same paths. A flag with another value (`--flag value` or
# `--flag=value`) dies. The flags that are missing are stored, space-separated,
# in UNIT_LAUNCH_EXTRA_ARGS (a function cannot rewrite the caller's "$@"; the
# values are the readonly literals, free of whitespace and glob characters, so
# the caller appends them with an unquoted expansion). --no-daemon is added when
# absent: a daemonizing freeunitd would leave the container's main process to
# exit. Args: <binary> [args...]
build_unit_launch_args() {
    _ep_bula_binary=$1
    shift
    _ep_bula_given=' '
    while [ "$#" -gt 0 ]; do
        _ep_bula_arg=$1
        shift
        if [ "$_ep_bula_arg" = --no-daemon ]; then
            _ep_bula_given="$_ep_bula_given--no-daemon "
            continue
        fi
        _ep_bula_flag=${_ep_bula_arg%%=*}
        _ep_bula_want=$(unit_launch_flag_value "$_ep_bula_flag")
        if [ -z "$_ep_bula_want" ]; then
            continue
        fi
        if [ "$_ep_bula_flag" != "$_ep_bula_arg" ]; then
            _ep_bula_value=${_ep_bula_arg#*=}
        else
            _ep_bula_value=${1-}
            if [ "$#" -gt 0 ]; then
                shift
            fi
        fi
        if [ "$_ep_bula_value" != "$_ep_bula_want" ]; then
            die "$_ep_bula_binary $_ep_bula_flag '$_ep_bula_value' conflicts with the entrypoint path '$_ep_bula_want'; drop the flag, the entrypoint adds it"
        fi
        _ep_bula_given="$_ep_bula_given$_ep_bula_flag "
    done
    UNIT_LAUNCH_EXTRA_ARGS=
    for _ep_bula_flag in --no-daemon --control --pid --statedir --tmpdir; do
        case "$_ep_bula_given" in
            *" $_ep_bula_flag "*) ;;
            *)
                UNIT_LAUNCH_EXTRA_ARGS="$UNIT_LAUNCH_EXTRA_ARGS $_ep_bula_flag"
                _ep_bula_want=$(unit_launch_flag_value "$_ep_bula_flag")
                if [ -n "$_ep_bula_want" ]; then
                    UNIT_LAUNCH_EXTRA_ARGS="$UNIT_LAUNCH_EXTRA_ARGS $_ep_bula_want"
                fi
                ;;
        esac
    done
}

# --- Trust guards ---------------------------------------------------------

# Refuse a file that will be sourced into the entrypoint shell if the container
# process could have authored it: owned by a non-root user, or group/world
# writable. Used to guard the hook dir, whose files the dispatcher sources
# before the launch. A file COPYed into the image (root:root, not
# world-writable) passes; one that the unprivileged process could rewrite (a
# compromised app persisting code into the next start) is rejected. Args: <file>
assert_safe_root_file() {
    if [ -n "$(find "$1" -maxdepth 0 \( ! -user 0 -o -perm -0002 -o -perm -0020 \) 2>/dev/null)" ]; then
        die "refusing to use entrypoint file with unsafe ownership/permissions (must be root-owned and not group/world-writable): $1"
    fi
    return 0
}

# --- Command dispatch (for the entrypoint and child launch modes) ---------

# True when a shell function handle_<cmd> exists. POSIX sh has no `declare -F`:
# `command -v NAME` prints NAME itself for a function (or a builtin or alias,
# which no handle_* is), and a path for an executable in PATH, so the output must
# equal the name. A command word with characters outside [A-Za-z0-9_] can never
# name a function and never matches. Args: <cmd>
has_handler() {
    case "$1" in
        '' | *[!A-Za-z0-9_]*) return 1 ;;
    esac
    [ "$(command -v "handle_$1" 2>/dev/null)" = "handle_$1" ]
}

# If a hook defined a function handle_<cmd>, invoke it: it owns the launch and
# MUST exec the final process. Reaching the end means it returned (or exited
# non-zero) instead of exec'ing - a contract violation, so die loudly rather than
# let the caller fall through to `exec "$@"` and double-run the command. The
# handler runs on the left of `||`, so `set -e` is off inside it (POSIX): a
# handler checks its own errors. No-op (returns 0) when no handler matches, so
# the caller proceeds with its default launch path. Args: <cmd> [args...]
dispatch_handler() {
    has_handler "${1:-}" || return 0
    "handle_$1" "$@" \
        || die "entrypoint hook handle_$1 exited $? without exec; a handler must exec the final process"
    die "entrypoint hook handle_$1 returned without exec; a handler must exec the final process"
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
    _ep_ucf_code=$?
    [ "$_ep_ucf_code" -eq 0 ] && return 0
    log_notice "initial configuration failed (exit $_ep_ucf_code); wiping $UNIT_STATE_DIR so it is retried on next start"
    # TERM, then a bounded wait for the process to actually exit before the wipe,
    # so `find -delete` does not race a freeunitd still writing to the state dir. The
    # wait is on the pid (not the control socket): on the failure path freeunitd may be
    # wedged, and blocking on a socket that never disappears would hang the EXIT
    # trap. Bounded by UNIT_STOP_TIMEOUT_TICKS, then SIGKILL, so the trap always
    # makes progress.
    _ep_ucf_ticks=0
    _ep_ucf_pid=$(read_pid "$UNIT_PID_FILE")
    # The master writes its pidfile asynchronously after forking, so if the
    # failure was wait_for_control_socket timing out on a slow/early-dying start,
    # the pid may not be readable yet. Briefly wait for it to appear so we TERM the
    # real master instead of letting the wipe race a daemon still coming up.
    if [ -z "$_ep_ucf_pid" ]; then
        while [ "$_ep_ucf_ticks" -lt "$UNIT_STOP_TIMEOUT_TICKS" ]; do
            sleep 0.1
            _ep_ucf_ticks=$((_ep_ucf_ticks + 1))
            _ep_ucf_pid=$(read_pid "$UNIT_PID_FILE")
            if [ -n "$_ep_ucf_pid" ]; then
                break
            fi
        done
        _ep_ucf_ticks=0
    fi
    if [ -n "$_ep_ucf_pid" ]; then
        kill -TERM "$_ep_ucf_pid" 2>/dev/null || true
        while kill -0 "$_ep_ucf_pid" 2>/dev/null; do
            if [ "$_ep_ucf_ticks" -ge "$UNIT_STOP_TIMEOUT_TICKS" ]; then
                kill -KILL "$_ep_ucf_pid" 2>/dev/null || true
                break
            fi
            sleep 0.1
            _ep_ucf_ticks=$((_ep_ucf_ticks + 1))
        done
    fi
    # -xdev: stop at filesystem boundaries so a host volume bind-mounted *inside*
    # the state dir is never wiped on the host. The generated dir lives as long as
    # the state: the scripts render it again on the retry.
    find "$UNIT_STATE_DIR" "$ENTRYPOINT_GENERATED_DIR" -xdev -mindepth 1 -delete 2>/dev/null || true
}

# Log every file of DIR (recursive, hidden ones skipped) whose name does not end
# in one of the given suffixes. Args: <dir> <note> <suffix>...
log_ignored_files() {
    _ep_lif_dir=$1
    _ep_lif_note=$2
    shift 2
    _ep_lif_list=$(list_entrypoint_files "$_ep_lif_dir" '') || exit 1
    while IFS= read -r _ep_lif_file <&4; do
        [ -n "$_ep_lif_file" ] && [ -f "$_ep_lif_file" ] || continue
        _ep_lif_known=
        for _ep_lif_suffix in "$@"; do
            case "$_ep_lif_file" in
                *"$_ep_lif_suffix") _ep_lif_known=1 ;;
            esac
        done
        if [ -z "$_ep_lif_known" ]; then
            log_notice "ignoring $_ep_lif_file$_ep_lif_note"
        fi
    done 4<<EOF
$_ep_lif_list
EOF
}

# The full first-run routine, composed from the core functions above so a child
# launch mode can call it or reuse the pieces: on a fresh state dir with config
# present, launch freeunitd, run the *.sh of ENTRYPOINT_CONFIG_DIR, upload the
# *.pem and PUT the *.json of ENTRYPOINT_CONFIG_DIR and then of
# ENTRYPOINT_GENERATED_DIR (what the scripts rendered; its last PUT wins), then
# stop it so the real start boots a populated state. Certificates of both dirs go
# before any config, so a rendered config may reference a baked bundle and vice
# versa. With UNIT_STATE_DIR on a tmpfs this runs on every container start.
# SIGTERM/SIGINT during the round exit 143/130 through the EXIT trap, so a
# `docker stop` mid-configuration wipes the state like a failure (a shell
# killed by an untrapped signal runs no EXIT trap, and a persistent /run would
# keep a partial config). The traps take effect once the foreground command
# (a script, curl, sleep 0.1) returns. It
# (and its EXIT trap unit_config_failed) work on the default UNIT_* paths only; a
# child that needs different state/socket/pid paths should compose the pieces
# directly rather than call this. Args: <binary> (the freeunitd binary name).
unit_initial_configuration() {
    if ! is_first_run; then
        log_notice "$UNIT_STATE_DIR is not empty, skipping initial configuration..."
        return 0
    fi
    if ! dir_has_content "$ENTRYPOINT_CONFIG_DIR" && ! dir_has_content "$ENTRYPOINT_GENERATED_DIR"; then
        log_notice "$ENTRYPOINT_CONFIG_DIR is empty, skipping initial configuration..."
        return 0
    fi

    trap unit_config_failed EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT

    log_info "$ENTRYPOINT_CONFIG_DIR is not empty, launching Unit daemon to perform initial configuration..."
    start_unit "$1"
    wait_for_control_socket

    log_info "looking for shell scripts in $ENTRYPOINT_CONFIG_DIR..."
    run_entrypoint_scripts
    log_info "looking for certificate bundles in $ENTRYPOINT_CONFIG_DIR and $ENTRYPOINT_GENERATED_DIR..."
    apply_certificates
    apply_certificates "$ENTRYPOINT_GENERATED_DIR"
    log_info "looking for configuration snippets in $ENTRYPOINT_CONFIG_DIR and $ENTRYPOINT_GENERATED_DIR..."
    apply_config
    apply_config "$ENTRYPOINT_GENERATED_DIR"

    # warn on filetypes we don't know what to do with
    log_ignored_files "$ENTRYPOINT_CONFIG_DIR" '' .sh .json .pem
    log_ignored_files "$ENTRYPOINT_GENERATED_DIR" \
        " (only *.pem and *.json are applied from $ENTRYPOINT_GENERATED_DIR)" .json .pem

    log_info "stopping Unit daemon after initial configuration..."
    stop_unit

    log_notice "unit initial configuration complete; ready for start up..."
    trap - EXIT TERM INT
}
