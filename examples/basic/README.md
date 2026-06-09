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
  --cap-drop=ALL --cap-add=SETUID --cap-add=SETGID \
  --security-opt=no-new-privileges \
  freeunit-php-example
```

## What it shows

- [`Dockerfile`](Dockerfile) — `FROM` the published GHCR base, then `COPY www/`
  (the app, including `index.php`) to `/www/` and `config.json` to
  `/docker-entrypoint.d/`. The entrypoint applies that config on first start; no
  runtime mounts.
- Hardening — `cap_drop: [ALL]` then `cap_add: [SETUID, SETGID]` plus
  `no-new-privileges`: the Unit master starts as root and needs only those two
  capabilities to drop each worker to the app user/group.
- `config.json` sets the application's `user` / `group` to `unit`, so the PHP
  worker itself runs unprivileged (the recommended way to drop privileges — not
  by changing the container user).
