#!/usr/bin/env bash

if [ -z "${UNIT_ENTRYPOINT_QUIET_LOGS:-}" ]; then
    exec 3>&2
else
    exec 3>/dev/null
fi

ngx_log() {
    local type="$1"
    shift
    printf '%s [%s] %s#%s [entrypoint] #0: %s\n' "$(date +'%Y/%m/%d %H:%M:%S')" "$type" "$$" "$$" "$*" >&3
}

ngx_err() {
    ngx_log err "$@"
    exit 1
}

ngx_warn() {
    ngx_log warning "$@"
}

ngx_notice() {
    ngx_log notice "$@"
}

ngx_info() {
    ngx_log info "$@"
}

curl_put() {
    local response status body
    # -w '%{http_code}' appends the 3-digit status (000 on a transport failure)
    # right after the body; a non-zero curl exit means it never reached the socket.
    if ! response=$(curl -s -w '%{http_code}' -X PUT --data-binary "@$1" \
        --unix-socket /var/run/control.unit.sock "http://localhost/$2"); then
        ngx_err "curl failed to PUT '$1' to 'config/$2'"
    fi
    status=${response: -3}
    body=${response%???}
    # Unit's control API answers 200 today; accept any 2xx so a future endpoint
    # returning 201/202 is not misread as a failure.
    case "$status" in
        2??)
            ngx_info "HTTP response status code is '$status'. Body: $body"
            ;;
        *)
            ngx_err "unexpected HTTP status '$status' while applying '$1'. Body: $body"
            ;;
    esac
}

APPLICATION_USER=${APPLICATION_USER:="unit"}
APPLICATION_UID=${APPLICATION_UID:="1000"}
APPLICATION_GROUP=${APPLICATION_GROUP:="unit"}
APPLICATION_GID=${APPLICATION_GID:="1000"}
APPLICATION_CHOWN=${APPLICATION_CHOWN:="yes"}

case "$APPLICATION_UID$APPLICATION_GID" in
    *[!0-9]*)
        ngx_err "APPLICATION_UID/APPLICATION_GID must be numeric (got '$APPLICATION_UID' / '$APPLICATION_GID')"
        ;;
esac

# An existing group/user keeps its own GID/UID — the core unit package's postinst
# already created the 'unit' user with a system-range UID, so the requested
# APPLICATION_UID/GID is ignored in that case; say so instead of failing silently.
if getent group "$APPLICATION_GROUP" >/dev/null; then
    ngx_info "app group '$APPLICATION_GROUP' already exists; keeping its GID, ignoring APPLICATION_GID='$APPLICATION_GID'"
else
    ngx_info "create app group: '$APPLICATION_GROUP' (gid $APPLICATION_GID)"
    groupadd "$APPLICATION_GROUP" -g "$APPLICATION_GID"
fi

if getent passwd "$APPLICATION_USER" >/dev/null; then
    ngx_info "app user '$APPLICATION_USER' already exists; keeping its UID, ignoring APPLICATION_UID='$APPLICATION_UID'"
else
    ngx_info "create app user: '$APPLICATION_USER' (uid $APPLICATION_UID)"
    useradd -M -s /bin/bash -g "$APPLICATION_GROUP" -u "$APPLICATION_UID" "$APPLICATION_USER"
fi

# APPLICATION_DIR must be a container-owned path: with APPLICATION_CHOWN=yes its
# ownership is rewritten, so pointing it at a host bind-mount rewrites host files.
# The chown below uses -xdev to stop at filesystem boundaries, so nested mounts
# under APPLICATION_DIR are not traversed and rewritten.
if [ -n "${APPLICATION_DIR:-}" ]; then
    if [ ! -d "$APPLICATION_DIR" ]; then
        ngx_info "create app dir: '$APPLICATION_DIR'"
        mkdir -p "$APPLICATION_DIR"
    fi
    if ! usermod --home "$APPLICATION_DIR" "$APPLICATION_USER" >/dev/null 2>&1; then
        ngx_warn "failed to set home of '$APPLICATION_USER' to '$APPLICATION_DIR'"
    fi
    if [ "$APPLICATION_CHOWN" = "yes" ]; then
        find "$APPLICATION_DIR" -xdev \! -user "$APPLICATION_USER" -exec chown "$APPLICATION_USER":"$APPLICATION_GROUP" '{}' +
    fi
fi
