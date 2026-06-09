# HTTPS the right way through the entrypoint's APPLICATOR CHAIN. On first start
# the entrypoint runs, in order: *.sh (generate the cert) -> *.pem (upload it as a
# TLS bundle) -> *.json (declare the TLS listener that references it). This image
# bakes all three plus a tiny app; nothing is mounted.
FROM ghcr.io/6run0/freeunit-php:trixie-php8.4

# openssl is needed by the first-run cert generator. Pin nothing else: it is a
# Debian package from the base image's apt sources.
# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends openssl; \
    rm -rf /var/lib/apt/lists/*

COPY www/ /www/

# The applicator chain, all baked into the runtime config dir. Order matters and
# is what makes TLS work end to end:
#   10-generate-cert.sh  writes webapp.pem (chain + key) into this same dir
#   apply_certificates   uploads webapp.pem as the `webapp` TLS bundle
#   config.json          declares the *:8443 TLS listener using "certificate":"webapp"
# Do NOT bind-mount /docker-entrypoint.d from the host: it holds the private key,
# and it must stay root-writable for the generator to run on first start.
COPY docker-entrypoint.d/10-generate-cert.sh /docker-entrypoint.d/10-generate-cert.sh
COPY config.json /docker-entrypoint.d/config.json
