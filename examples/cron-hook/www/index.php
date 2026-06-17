<?php

// Web role of the cron-hook example: served by the Unit master that the default
// `freeunitd` command starts. Serving this at all confirms the embedded PHP module
// loaded and FreeUnit routed the request to it.
header('Content-Type: text/plain; charset=utf-8');

echo "freeunit-php cron-hook example - web role\n";
echo 'served by PHP ' . PHP_VERSION . " through FreeUnit\n";
echo "the cron role runs cron-task.php from this same image: docker compose logs cron\n";
