<?php

// Served on the TLS listener (*:8443). Reaching this over https proves the whole
// applicator chain worked: the *.sh generated the cert, *.pem uploaded it as the
// `webapp` bundle, and *.json declared the TLS listener that references it.
header('Content-Type: text/plain; charset=utf-8');

echo "freeunit-php web-app example\n";
echo 'served over TLS by PHP ' . PHP_VERSION . " through FreeUnit\n";
echo "the certificate was generated and uploaded by the entrypoint applicator chain\n";
