<?php
/**
 * Fired during plugin deactivation.
 *
 * @package {{PLUGIN_CLASS}}
 */

namespace {{PLUGIN_CLASS}};

/**
 * Class Deactivator
 */
class Deactivator {

	/**
	 * Run on plugin deactivation.
	 *
	 * Clean up scheduled events, flush rewrite rules, etc.
	 */
	public static function deactivate(): void {
		flush_rewrite_rules();
	}
}
