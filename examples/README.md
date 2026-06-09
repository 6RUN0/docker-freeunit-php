# Examples

Each subdirectory is a self-contained example built on the `freeunit-php` base
image. Pick one, `cd` into it, and `docker compose up --build`.

- [`basic/`](basic/) — the minimal self-contained, security-hardened deployment:
  a small `Dockerfile` bakes an app and its Unit config onto the base image, run
  with the recommended capability hardening. Start here.
- [`cron-hook/`](cron-hook/) — the entrypoint hook system: one image runs in two
  roles (the Unit web server and a long-lived `supercronic` cron runner),
  selected per container by the command, with no second image and no forked
  entrypoint.
