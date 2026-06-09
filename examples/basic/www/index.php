<?php

// Example landing page for the docker-compose deployment. Serving this at all
// confirms the embedded PHP module loaded and FreeUnit routed a request to it.
header('Content-Type: text/plain; charset=utf-8');

echo "freeunit-php example app\n";
echo 'served by PHP ' . PHP_VERSION . " through FreeUnit\n";
