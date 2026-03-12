<?php
/**
 * PHPUnit bootstrap file.
 *
 * @package {{PLUGIN_CLASS}}\Tests
 */

// Load Composer autoloader.
require_once dirname( __DIR__ ) . '/vendor/autoload.php';

// Bootstrap WP_Mock.
WP_Mock::bootstrap();
