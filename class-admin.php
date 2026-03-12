<?php
/**
 * Admin-facing functionality.
 *
 * @package {{PLUGIN_CLASS}}\Admin
 */

namespace {{PLUGIN_CLASS}}\Admin;

/**
 * Class AdminController
 */
class AdminController {

	public function __construct(
		private readonly string $plugin_slug,
		private readonly string $version
	) {}

	/**
	 * Enqueue admin CSS.
	 */
	public function enqueue_styles( string $hook ): void {
		if ( ! $this->is_plugin_page( $hook ) ) {
			return;
		}

		wp_enqueue_style(
			$this->plugin_slug . '-admin',
			{{PLUGIN_CLASS}}_URL . 'admin/css/admin.css',
			[],
			$this->version
		);
	}

	/**
	 * Enqueue admin JS.
	 */
	public function enqueue_scripts( string $hook ): void {
		if ( ! $this->is_plugin_page( $hook ) ) {
			return;
		}

		wp_enqueue_script(
			$this->plugin_slug . '-admin',
			{{PLUGIN_CLASS}}_URL . 'admin/js/admin.js',
			[ 'jquery' ],
			$this->version,
			true
		);

		wp_localize_script(
			$this->plugin_slug . '-admin',
			'{{PLUGIN_CLASS}}Admin',
			[
				'ajaxUrl' => admin_url( 'admin-ajax.php' ),
				'nonce'   => wp_create_nonce( $this->plugin_slug . '-admin-nonce' ),
			]
		);
	}

	/**
	 * Register admin menu pages.
	 */
	public function add_menu_pages(): void {
		add_menu_page(
			__( '{{PLUGIN_NAME}}', '{{PLUGIN_SLUG}}' ),
			__( '{{PLUGIN_NAME}}', '{{PLUGIN_SLUG}}' ),
			'manage_options',
			$this->plugin_slug,
			[ $this, 'render_main_page' ],
			'dashicons-admin-plugins',
			80
		);

		add_submenu_page(
			$this->plugin_slug,
			__( 'Settings', '{{PLUGIN_SLUG}}' ),
			__( 'Settings', '{{PLUGIN_SLUG}}' ),
			'manage_options',
			$this->plugin_slug . '-settings',
			[ $this, 'render_settings_page' ]
		);
	}

	/**
	 * Render the main admin page.
	 */
	public function render_main_page(): void {
		if ( ! current_user_can( 'manage_options' ) ) {
			return;
		}
		include {{PLUGIN_CLASS}}_DIR . 'admin/views/main.php';
	}

	/**
	 * Render the settings page.
	 */
	public function render_settings_page(): void {
		if ( ! current_user_can( 'manage_options' ) ) {
			return;
		}

		if ( isset( $_POST['{{PLUGIN_SLUG}}_save_settings'] ) ) {
			$this->save_settings();
		}

		include {{PLUGIN_CLASS}}_DIR . 'admin/views/settings.php';
	}

	/**
	 * Save settings from POST data.
	 */
	private function save_settings(): void {
		check_admin_referer( '{{PLUGIN_SLUG}}-save-settings', '{{PLUGIN_SLUG}}_nonce' );

		$settings = [
			'enabled'     => isset( $_POST['enabled'] ) ? (bool) $_POST['enabled'] : false,
			'setting_one' => sanitize_text_field( wp_unslash( $_POST['setting_one'] ?? '' ) ),
		];

		update_option( '{{PLUGIN_SLUG}}_settings', $settings );
		add_action( 'admin_notices', fn() =>
			print '<div class="notice notice-success is-dismissible"><p>' .
			esc_html__( 'Settings saved.', '{{PLUGIN_SLUG}}' ) . '</p></div>'
		);
	}

	/**
	 * Check if we're on a plugin admin page.
	 */
	private function is_plugin_page( string $hook ): bool {
		return str_contains( $hook, $this->plugin_slug );
	}
}
