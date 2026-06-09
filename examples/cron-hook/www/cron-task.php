<?php

// Cron role of the cron-hook example: run on a schedule by supercronic, which
// the handle_supercronic entrypoint hook starts. This is the SAME image that
// serves index.php in the web role -- the only difference is the command, and
// therefore the launch mode the hook selects. Writing to stdout is enough:
// supercronic captures it, so `docker compose logs cron` shows each run.
fwrite(STDOUT, sprintf(
    "[%s] cron-task ran via supercronic on PHP %s\n",
    date('c'),
    PHP_VERSION
));
