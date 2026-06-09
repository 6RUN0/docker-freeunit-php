# Example: multiple apps, routing, and per-app PHP config

One image serves **two** PHP applications behind URI routing, with a static-file
`share` in front of a front controller. It also shows the per-application PHP
knobs: `options.admin` / `options.user`, a per-app `php.ini` via `options.file`,
and the Unit `environment` block.

## Run

```bash
docker compose up --build        # from this directory
```

Then:

```bash
curl http://localhost:8080/                  # site front controller (diagnostic page)
curl http://localhost:8080/assets/style.css  # static file, served directly by `share`
curl http://localhost:8080/admin/            # the second app: different memory_limit
```

## How the routing works

The listener passes to a route ([`config.json`](config.json), `routes/main`) with
two steps, evaluated in order:

1. **`match` `uri = /admin/*` → `pass applications/admin`.** Anything under
   `/admin/` goes to the second app.
2. **no match → `share /www/public$uri` with `fallback` → `applications/site`.**
   Everything else tries to serve a real file from `/www/public`; if none exists,
   it falls back to the `site` front controller. This is the classic split:
   static assets come off disk, dynamic paths go to PHP.

`/www/public/assets/style.css` exists on disk, so `GET /assets/style.css` is
served by `share` and never reaches PHP — proof the static path works. `GET /`
has no matching file, so it falls back to `site/index.php`.

## Per-app PHP configuration

- **`site`** sets `memory_limit` and `display_errors=0` via **`options.admin`**
  (non-overridable by the app), `date.timezone` via **`options.user`**
  (overridable), and `APP_ENV` / `APP_GREETING` via the **`environment`** block.
  The page reads them back with `ini_get` / `getenv`.
- **`admin`** loads a per-app **`options.file`** (`/www/admin/php.ini`) with a
  different `memory_limit`. So `GET /` reports `256M` and `GET /admin/` reports
  `512M` from the same image — independent PHP config per application.

## A note on the diagnostic page

The `site` page prints the PHP version, loaded extension list, config values, and
environment **on purpose**, to demonstrate the image's capabilities. That makes it
a stack-fingerprinting surface: in production, remove such an endpoint or put it
behind authentication, and never echo `getenv()` of arbitrary environment into a
response — real deployments keep secrets in env. It does not call `phpinfo()`;
it checks specific extensions (`apcu`, `redis`, `gd`, `intl`, `mbstring`) the base
image ships.

## What it shows

- [`config.json`](config.json) — one listener, a two-step route (URI match +
  share/fallback), and two PHP applications with distinct `options` and
  `environment`.
- Hardening — the same `cap_drop: [ALL]` + `cap_add: [SETUID, SETGID]` +
  `no-new-privileges` block as [`basic/`](../basic/), so the workers run
  unprivileged.

## Verify

```bash
docker compose up --build -d
curl -s http://localhost:8080/ | grep 'memory_limit = 256M'          # site options.admin
curl -s http://localhost:8080/admin/ | grep 'memory_limit = 512M'    # admin options.file
curl -sI http://localhost:8080/assets/style.css | head -n1           # 200, served by share
docker compose down -v
```
