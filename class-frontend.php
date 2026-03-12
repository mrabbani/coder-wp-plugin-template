<?php
/**
 * Public-facing functionality.
 *
 * @package {{PLUGIN_CLASS}}\Frontend
 */

namespace {{PLUGIN_CLASS}}\Frontend;

/**
 * Class FrontendController
 */
class FrontendController {

	public function __construct(
		private readonly string $plugin_slug,
		private readonly string $version
	) {}

	/**
	 * Enqueue public CSS.
	 */
	public function enqueue_styles(): void {
		wp_enqueue_style(
			$this->plugin_slug . '-public',
			{{PLUGIN_CLASS}}_URL . 'public/css/public.css',
			[],
			$this->version
		);
	}

	/**
	 * Enqueue public JS.
	 */
	public function enqueue_scripts(): void {
		wp_enqueue_script(
			$this->plugin_slug . '-public',
			{{PLUGIN_CLASS}}_URL . 'public/js/public.js',
			[],
			$this->version,
			true
		);
	}
}
