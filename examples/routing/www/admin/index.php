<?php

// The `admin` application: a SECOND PHP app in the same image, reached when the
// request URI is under /admin/ (see the first route step in config.json). It
// loads its PHP config from a per-app php.ini via options.file, so its
// memory_limit differs from the site app's options.admin value -- proof that the
// two apps have independent PHP configuration.
header('Content-Type: text/plain; charset=utf-8');

echo "freeunit-php routing example -- admin (second app)\n";
echo 'served by PHP ' . PHP_VERSION . " through FreeUnit\n\n";
echo "memory_limit = " . ini_get('memory_limit') . " (from options.file = /www/admin/php.ini)\n";
