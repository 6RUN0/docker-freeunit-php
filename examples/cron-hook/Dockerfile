# Extend the freeunit-php base with a SECOND launch mode -- a long-lived cron
# runner -- added entirely through the entrypoint hook system. The same image
# then serves two roles, chosen per container by the command:
#
#   * default command `freeunitd`   -> the Unit web server (base image behavior)
#   * command `supercronic`     -> the cron runner (the hook in this example)
#
# No second Dockerfile, no overriding /docker-entrypoint.sh. See
# docker-compose.yml, which runs both roles from this one image.
FROM ghcr.io/6run0/freeunit-php:trixie-php8.4

# supercronic: a crontab-compatible job runner that runs as a single foreground
# process and logs every job to stdout -- exactly what a container service wants
# (unlike system cron, which daemonizes and logs to syslog). Pinned by version
# and SHA256 and verified on download, mirroring how the base image fetches and
# checks its own release assets. amd64 only, matching the base image's platform.
ARG SUPERCRONIC_VERSION=v0.2.46
ARG SUPERCRONIC_SHA256=5adff01c5a797663948e656d2b61d10932369ee437eb5cb54fa872b2960f222b
RUN set -eux; \
    curl -fsSL --retry 3 --retry-connrefused --proto-redir '=https' \
        -o /usr/local/bin/supercronic \
        "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64"; \
    # String test rather than a pipe into `sha256sum -c`, to keep the RUN free of
    # pipes (hadolint DL4006) -- `sha256sum FILE` prints "<hash>  FILE".
    [ "$(sha256sum /usr/local/bin/supercronic)" = "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" ] \
    || { echo "ERROR: supercronic digest does not match the pinned SUPERCRONIC_SHA256"; exit 1; }; \
    chmod 0755 /usr/local/bin/supercronic; \
    supercronic -version

# App code shared by BOTH roles: the web role serves www/index.php; the cron
# role runs www/cron-task.php on a schedule. One codebase, two entry points.
COPY www/ /www/

# Unit config for the web role, applied on first start by the base entrypoint.
# The cron role never reaches the first-run routine (the hook execs before it),
# so this file is simply ignored there.
COPY config.json /docker-entrypoint.d/config.json

# The crontab the cron role runs.
COPY crontab /etc/supercronic/crontab

# THE HOOK. A single file in the hook dir defines handle_supercronic. The base
# entrypoint sources it and dispatches to it when the command is `supercronic`.
# Because child images never overwrite /docker-entrypoint.sh, every base
# robustness/security fix still reaches this image.
COPY supercronic-hook.sh /docker-entrypoint-hook.d/supercronic.sh
