<?php
// SPDX-License-Identifier: MIT
// Local Windows/NTFS storage. Do not publish this service on a public interface.
$CONFIG = [
    'check_data_directory_permissions' => false,
    'allow_local_remote_servers' => true,
    'enable_previews' => false,
    'default_language' => 'zh_CN',
    'tempdirectory' => '/var/www/html/data/tmp',
    'loglevel' => 2,
    'log_rotate_size' => 10485760,
    'updatechecker' => false,
    'appstoreenabled' => false,
    'has_internet_connection' => false,
    'connectivity_check_domains' => [],
    'lookup_server' => '',
    'knowledgebaseenabled' => false,
    'simpleSignUpLink.shown' => false,
    // Archive website source files as data, including .htaccess.
    // Nextcloud still controls its .part/.filepart transfer restrictions.
    'forbidden_filenames' => [],
];
