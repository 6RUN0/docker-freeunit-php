# Example: HTTPS via the entrypoint applicator chain

This example shows the entrypoint's **applicator chain** end to end: on first
start the entrypoint processes `/docker-entrypoint.d` in a fixed order —
`*.sh`, then `*.pem`, then `*.json` — and TLS falls out of using all three
together:

1. **`*.sh`** ([`10-generate-cert.sh`](docker-entrypoint.d/10-generate-cert.sh))
   generates a self-signed bundle and writes it into
   `$ENTRYPOINT_GENERATED_DIR/webapp.pem` (`/run/docker-entrypoint.d`).
2. **`*.pem`** - `apply_certificates` uploads `webapp.pem` to the Unit control API
   as the certificate bundle named `webapp` (the `*.pem` of the generated dir go
   right after those of `/docker-entrypoint.d`).
3. **`*.json`** ([`config.json`](config.json)) declares a TLS listener on `*:8443`
   referencing `"certificate": "webapp"`, plus a plain `*:8080` listener that
   `return`s a 301 redirect to `https`.

The order is the whole point: the `*.sh` step produces the file the `*.pem` step
consumes, which produces the bundle the `*.json` step references.

## Run

```bash
docker compose up --build        # from this directory
```

Then:

```bash
curl -kI http://localhost:8080/   # 301 redirect to https
curl -k  https://localhost:8443/  # the app, served over TLS
```

## Security notes (read before copying this)

- **Self-signed = demo only.** A self-signed certificate provides encryption but
  **no authentication** — a client cannot verify the server's identity. For
  production, do not generate a cert: bake or mount a real CA-issued bundle as
  `webapp.pem` and delete [`10-generate-cert.sh`](docker-entrypoint.d/10-generate-cert.sh).
- **`curl -k` is a demo shortcut.** It disables certificate verification. Never
  use it against a real endpoint — it defeats the purpose of TLS.
- **The private key stays `0600` in `/run`.** The generator runs `umask 077` and
  `chmod 600` on the bundle, because `apply_certificates` does not set the mode
  itself. It lives in `/run/docker-entrypoint.d` (a tmpfs under `read_only`),
  never in the image or a host mount; `/docker-entrypoint.d` stays read-only for
  the container user.
- **TLS settings are Unit's defaults.** The listener sets only the certificate;
  protocol and cipher selection come from the build's OpenSSL defaults. For a real
  deployment, pin a floor (TLS 1.2+) via Unit's TLS configuration.

## What it shows

- The applicator order `*.sh` → `*.pem` → `*.json`, which is what makes a
  generate-then-upload-then-reference TLS flow work from a cold start.
- A TLS listener (`*:8443`) and an HTTP→HTTPS redirect (`*:8080`, `return` 301
  with `location`).
- Hardening - the same `cap_drop: [ALL]` + `no-new-privileges` block as
  [`basic/`](../basic/).
- A derived image that installs packages: `USER 0:0` before `apt-get`, then
  `USER 65532:65532` again (see the [`Dockerfile`](Dockerfile)).

## Verify

```bash
docker compose up --build -d
curl -ksI http://localhost:8080/ | grep -i '^location: https'   # 301 -> https
curl -ks  https://localhost:8443/ | grep 'served over TLS'      # app over TLS
docker compose down -v
```
