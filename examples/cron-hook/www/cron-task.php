<?php

// Cron role of the cron-hook example: run on a schedule by supercronic, which
// the handle_supercronic entrypoint hook starts. This is the SAME image that
// serves index.php in the web role -- the only difference is the command, and
// therefore the launch mode the hook selects. Writing to stdout is enough:
// supercronic captures it, so `docker compose logs cron` shows each run.
//
// The hook provisions a dedicated `worker` user (uid/gid 1500) via setup_user
// and drops to it with exec_as_user, so this task runs UNPRIVILEGED and NOT as
// `freeunit`. Print the effective identity to prove it -- the line reads like the
// `id` command: uid=1500(worker) gid=1500(worker).
$uid = posix_geteuid();
$gid = posix_getegid();
$uname = posix_getpwuid($uid)['name'] ?? '?';
$gname = posix_getgrgid($gid)['name'] ?? '?';

fwrite(STDOUT, sprintf(
    "[%s] cron-task ran via supercronic on PHP %s as uid=%d(%s) gid=%d(%s)\n",
    date('c'),
    PHP_VERSION,
    $uid,
    $uname,
    $gid,
    $gname
));
