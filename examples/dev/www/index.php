<?php

// Dev example landing page. Edit this file on the host and reload the browser:
// the change shows up with no rebuild, because ./www is bind-mounted and Unit
// re-reads PHP files per request. Change the text below to see it live.
header('Content-Type: text/plain; charset=utf-8');

echo "freeunit-php dev example\n";
echo 'served by PHP ' . PHP_VERSION . " through FreeUnit\n";
echo "edit www/index.php and reload -- no rebuild needed\n\n";

// Prove the writable named volume works: APPLICATION_DIR=/data with
// APPLICATION_CHOWN=yes made the entrypoint chown /data to the app user at
// startup, so this unprivileged worker can write there. Each request appends a
// timestamp and reads the file back.
$marker = '/data/visits.log';
file_put_contents($marker, date('c') . "\n", FILE_APPEND | LOCK_EX);

echo "wrote a timestamp to $marker (a writable named volume owned by the app user)\n";
echo "current contents:\n";
echo file_get_contents($marker);
