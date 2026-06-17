# Example: local development (iterate without rebuilding)

A development setup where PHP code is **bind-mounted**, so editing a file on the
host and reloading the page takes effect immediately — no `docker build`. It also
shows three image knobs you reach for while developing: choosing the PHP line at
build time, silencing the entrypoint logs, and getting a writable directory owned
by the app user.

## Run

```bash
docker compose up --build        # from this directory
```

Then open <http://localhost:8080/>. Edit [`www/index.php`](www/index.php), reload
the page, and your change is there — the app code is bind-mounted, and Unit
re-reads PHP files per request.

## What is live, and what is not

| You change… | Live? | How to apply |
| --- | --- | --- |
| `www/*.php` (app code) | yes | just reload the page |
| `PHP_VER` in [`.env`](.env) | no | `docker compose up --build` (it is a build arg) |
| `config.json` (Unit config) | no | `docker compose down -v` then `up` again |

The last row is the one that surprises people. The entrypoint applies
`config.json` **only on first start**, when Unit's state directory
(`/var/lib/freeunit`) is empty. After that the config lives in Unit's own state, so
editing the baked `config.json` does nothing until you reset that state with
`down -v`. PHP code has no such caveat — it is re-read every request.

## What it shows

- **Bind-mounted code** — [`docker-compose.yml`](docker-compose.yml) mounts
  `./www:/www:ro`. Read-only is deliberate: the app never writes into its own code
  tree. Edits on the host are visible immediately.
- **PHP line as a build arg** — the [`Dockerfile`](Dockerfile) takes
  `ARG PHP_VER` and the base tag is `…:trixie-php${PHP_VER}`; compose forwards it
  from [`.env`](.env). Set `PHP_VER=8.5` (or `8.3`) and `docker compose up --build`
  to develop against another PHP line. The page prints `PHP_VERSION`, so the switch
  is visible. The value must be a published tag (`8.3`, `8.4`, `8.5`).
- **`UNIT_ENTRYPOINT_QUIET_LOGS=1`** — silences the entrypoint's own info/notice
  lines, so the logs show your app, not the boot chatter.
- **`APPLICATION_DIR` + `APPLICATION_CHOWN`** — at startup the entrypoint (running
  as root, before it drops privileges) chowns `/data` to the app user, so the
  unprivileged PHP worker can write there. `/data` is a **named volume**, never a
  host bind-mount: `CHOWN=yes` rewrites the ownership of everything under the dir,
  which you do not want pointed at your host files. The page writes a timestamp to
  `/data/visits.log` and reads it back to prove the worker has write access.

  **Capability cost:** chowning the root-owned volume needs `CAP_CHOWN`, which
  `cap_drop: [ALL]` removes — so this example adds `cap_add: [CHOWN]` (see
  [`docker-compose.yml`](docker-compose.yml)). That is the price of the
  runtime-chown convenience. The more hardened alternative, if you do not want the
  extra capability, is to bake the ownership into the image
  (`RUN mkdir -p /data && chown app:app /data`) and keep `APPLICATION_CHOWN=no`: a
  fresh named volume inherits the mount point's ownership from the image, so the
  worker can write with no runtime chown and no `CAP_CHOWN`.

## Verify

```bash
docker compose up --build -d
curl http://localhost:8080/                       # page + PHP version + /data write-back

# Code edit is live (no rebuild):
sed -i 's/dev example/dev example (edited)/' www/index.php
curl http://localhost:8080/ | grep edited         # the edit shows up

# The /data write came from the unprivileged app user, not root:
docker compose exec app ls -ln /data/visits.log   # owner uid/gid is the app user's

# Config edits are NOT live until the state volume is reset:
docker compose down -v
```
