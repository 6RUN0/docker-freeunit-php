# Example: self-contained hardened image

A minimal app and its Unit config baked onto the `freeunit-php` base image via a
small [`Dockerfile`](Dockerfile), then run with the hardening recommended in the
[top-level README](../../README.md#security-posture). Nothing is bind-mounted — the
container is self-contained.

## Run

```bash
docker compose up --build        # from this directory
```

Then open <http://localhost:8080/>.

Equivalent without compose:

```bash
docker build -t freeunit-php-example .
docker run --rm -p 8080:8080 \
  --read-only \
  --tmpfs /run:size=16m,uid=65532,gid=65532,mode=0700 \
  --tmpfs /tmp:size=64m,uid=65532,gid=65532,mode=0700 \
  --cap-drop=ALL --security-opt=no-new-privileges \
  freeunit-php-example
```

## What it shows

- [`Dockerfile`](Dockerfile) — `FROM` the published GHCR base, then `COPY www/`
  (the app, including `index.php`) to `/www/` and `config.json` to
  `/docker-entrypoint.d/`. The entrypoint applies that config on first start; no
  runtime mounts.
- Hardening - `cap_drop: [ALL]` plus `no-new-privileges` and no `cap_add`: the
  image runs as the non-root user `nonroot` (65532), the Unit master and the PHP
  workers included, so it needs no capability. `read_only: true` with tmpfs
  `/run` (Unit socket, pid, state) and `/tmp` (request bodies, PHP temp files),
  both owned by 65532: nothing else in the container is writable.
- `config.json` has no `user` / `group` keys: an unprivileged Unit runs its
  workers as its own user.
