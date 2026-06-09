#!/bin/sh
#
# First-run *.sh applicator: generate a self-signed TLS bundle for the demo.
#
# DEMO ONLY. A self-signed certificate gives encryption but NO authentication --
# clients cannot verify the server's identity (which is why the README's checks
# use `curl -k`, disabling verification). For production, do NOT generate a cert:
# mount or bake a real CA-issued bundle as webapp.pem and delete this script.
#
# This runs as root during first-run, BEFORE apply_certificates. It writes the
# bundle into /docker-entrypoint.d so the next applicator step uploads it. Unit
# expects a bundle = certificate chain followed by the private key, in one file.
set -eu

cert=/docker-entrypoint.d/webapp.pem

# Idempotent: first-run only fires on an empty state dir, but guard anyway so a
# baked or mounted real cert is never overwritten.
[ -e "$cert" ] && exit 0

# umask 077 so the private key is not group/world-readable: apply_certificates
# does not chmod, so the file's mode is whatever we create it with.
umask 077
tmp="$(mktemp -d)"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$tmp/key.pem" -out "$tmp/crt.pem" \
    -days 365 -subj '/CN=localhost' >/dev/null 2>&1

# Chain THEN key, the order Unit's certificate bundle format requires.
cat "$tmp/crt.pem" "$tmp/key.pem" > "$cert"
chmod 600 "$cert"
rm -rf "$tmp"

echo "generated self-signed TLS bundle at $cert (DEMO cert -- not for production)"
