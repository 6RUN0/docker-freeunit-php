<?php

// DIAGNOSTIC PAGE -- demo only, do NOT ship as-is. It deliberately prints the
// PHP version, loaded extensions, config values, and environment, which together
// fingerprint the stack. In production this kind of endpoint must be removed or
// behind authentication, and you must never echo getenv() of arbitrary env into
// a response -- real deployments keep secrets in env.
//
// This is the `site` application: the front controller the route falls back to
// when no static file matched and the path is not under /admin/.
header('Content-Type: text/plain; charset=utf-8');

echo "freeunit-php routing example -- site (front controller)\n";
echo 'served by PHP ' . PHP_VERSION . " through FreeUnit\n\n";

// environment: the values come from the Unit `environment` block for this app.
echo "APP_ENV      = " . getenv('APP_ENV') . "\n";
echo "APP_GREETING = " . getenv('APP_GREETING') . "\n\n";

// options: memory_limit is set via options.admin (non-overridable) for this app;
// the admin app gets a different value from its options.file php.ini.
echo "memory_limit = " . ini_get('memory_limit') . " (from options.admin)\n";
echo "date.timezone = " . ini_get('date.timezone') . " (from options.user)\n\n";

// extensions: a few of the modules the base image ships, proving the rich set.
echo "loaded extensions:\n";
foreach (['apcu', 'redis', 'gd', 'intl', 'mbstring'] as $ext) {
    echo "  $ext: " . (extension_loaded($ext) ? 'yes' : 'no') . "\n";
}
