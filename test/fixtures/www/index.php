<?php

// Minimal app used by the smoke test: the marker proves the PHP module loaded
// and actually served a request through FreeUnit. session.save_path proves the
// image's conf.d reached the embed SAPI; a POSTed file reports where PHP
// stored it (the request body itself is buffered by Unit in its --tmpdir).
echo 'freeunit-php-smoke-ok php=' . PHP_VERSION;
echo ' session.save_path=' . ini_get('session.save_path');
if (isset($_FILES['upload']['tmp_name']) && $_FILES['upload']['error'] === UPLOAD_ERR_OK) {
    echo ' upload_dir=' . dirname($_FILES['upload']['tmp_name']);
    echo ' upload_size=' . $_FILES['upload']['size'];
}
