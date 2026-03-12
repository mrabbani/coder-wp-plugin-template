#!/usr/bin/env bash
set -euo pipefail

PLUGIN_SLUG="${PLUGIN_SLUG:-my-wordpress-plugin}"
PLUGIN_NAME="${PLUGIN_NAME:-My WordPress Plugin}"
WORKSPACE="/home/coder/workspace"
PLUGIN_DIR="$WORKSPACE/plugin"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  WordPress Plugin Dev Workspace"
echo "  Plugin: $PLUGIN_NAME ($PLUGIN_SLUG)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

mkdir -p "$WORKSPACE"

# ── Wait for MySQL ────────────────────────────────────────────────────────────
echo "⏳ Waiting for MySQL..."
until mysqladmin ping -h"${WP_HOST:-localhost}" --silent 2>/dev/null; do
  sleep 2
done
echo "✅ MySQL ready"

# ── Wait for WordPress ────────────────────────────────────────────────────────
echo "⏳ Waiting for WordPress container..."
sleep 5

# ── Scaffold plugin if not exists ────────────────────────────────────────────
if [ ! -f "$PLUGIN_DIR/composer.json" ]; then
  echo "📦 Scaffolding plugin: $PLUGIN_SLUG..."
  mkdir -p "$PLUGIN_DIR"
  cp -r /home/coder/plugin-template/. "$PLUGIN_DIR/"

  # Replace placeholders
  find "$PLUGIN_DIR" -type f \( -name "*.php" -o -name "*.json" -o -name "*.txt" -o -name "*.md" \) \
    -exec sed -i \
      -e "s/{{PLUGIN_NAME}}/$PLUGIN_NAME/g" \
      -e "s/{{PLUGIN_SLUG}}/$PLUGIN_SLUG/g" \
      -e "s/{{PLUGIN_CLASS}}/$(echo "$PLUGIN_SLUG" | sed 's/-/_/g' | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1))substr($i,2)}}1' FS='_' OFS='_')/g" \
      -e "s/{{YEAR}}/$(date +%Y)/g" \
      {} \;

  echo "✅ Plugin scaffolded at $PLUGIN_DIR"
fi

# ── Install composer dependencies ────────────────────────────────────────────
if [ -f "$PLUGIN_DIR/composer.json" ]; then
  echo "📦 Installing Composer dependencies..."
  cd "$PLUGIN_DIR" && composer install --no-interaction 2>&1 | tail -5
fi

# ── Install npm dependencies ──────────────────────────────────────────────────
if [ -f "$PLUGIN_DIR/package.json" ]; then
  echo "📦 Installing npm dependencies..."
  cd "$PLUGIN_DIR" && npm install --silent
fi

# ── Configure WP-CLI ─────────────────────────────────────────────────────────
mkdir -p ~/.wp-cli
cat > ~/.wp-cli/config.yml <<EOF
path: /var/www/html
url: http://localhost:8080
user: admin
EOF

# ── Install WordPress via WP-CLI (if not installed) ──────────────────────────
echo "⚙️  Configuring WordPress..."
wp --path=/var/www/html core install \
  --url="http://localhost:8080" \
  --title="Plugin Dev — $PLUGIN_NAME" \
  --admin_user=admin \
  --admin_password=admin \
  --admin_email=dev@local.test \
  --skip-email 2>/dev/null || echo "ℹ️  WordPress already installed"

wp --path=/var/www/html plugin activate "$PLUGIN_SLUG" 2>/dev/null || true

# ── Start code-server ─────────────────────────────────────────────────────────
echo "🚀 Starting VS Code server..."
code-server \
  --bind-addr 127.0.0.1:8081 \
  --auth none \
  --disable-telemetry \
  "$WORKSPACE" &

# ── Start phpMyAdmin ──────────────────────────────────────────────────────────
echo "🚀 Starting phpMyAdmin..."
cat > /tmp/pma-config.php <<'PMAEOF'
<?php
$cfg['Servers'][1]['host'] = getenv('WP_HOST') ?: 'localhost';
$cfg['Servers'][1]['user'] = 'wordpress';
$cfg['Servers'][1]['password'] = 'wordpress';
$cfg['Servers'][1]['auth_type'] = 'config';
$cfg['blowfish_secret'] = 'dev-secret-key-change-in-prod';
PMAEOF
cp /tmp/pma-config.php /opt/phpmyadmin/config.inc.php
php -S 127.0.0.1:8082 -t /opt/phpmyadmin/ &>/tmp/phpmyadmin.log &

# ── Claude Code setup ─────────────────────────────────────────────────────────
if command -v claude &>/dev/null; then
  echo ""
  echo "🤖 Claude Code is ready!"
  echo "   Run: claude"
  echo "   Or:  claude chat 'help me add a settings page to my plugin'"
  echo ""
  # Write a CLAUDE.md project context file
  if [ ! -f "$PLUGIN_DIR/CLAUDE.md" ]; then
    cat > "$PLUGIN_DIR/CLAUDE.md" <<CLAUDEEOF
# Claude Code — WordPress Plugin Context

## Project
- **Plugin**: $PLUGIN_NAME
- **Slug**: $PLUGIN_SLUG
- **Entry point**: \`$PLUGIN_SLUG.php\`

## Stack
- PHP ${PHP_VERSION:-8.2} + WordPress hooks/filters
- Composer for autoloading (PSR-4 under \`$PLUGIN_SLUG\` namespace)
- PHPUnit + WP_Mock for tests
- @wordpress/scripts for JS/CSS bundling

## Structure
\`\`\`
$PLUGIN_SLUG/
├── $PLUGIN_SLUG.php        # Main plugin file & bootstrap
├── includes/               # Core PHP classes
│   ├── class-plugin.php    # Main plugin class
│   ├── class-activator.php # Activation hook
│   └── class-deactivator.php
├── admin/                  # Admin-facing code
│   ├── class-admin.php
│   ├── css/
│   └── js/
├── public/                 # Front-end code
│   ├── class-public.php
│   ├── css/
│   └── js/
├── languages/              # i18n .pot file
├── tests/                  # PHPUnit tests
└── src/                    # JS/SCSS source (built by wp-scripts)
\`\`\`

## Common Tasks
- Run tests: \`composer test\`
- Build assets: \`npm run build\`
- Watch assets: \`npm run start\`
- Lint PHP: \`composer lint\`
- WP-CLI: \`wp help\`

## WordPress Coding Standards
Follow the WordPress Coding Standards:
- Use \`wp_\` prefix for global functions
- Sanitize inputs: \`sanitize_text_field()\`, \`absint()\`, etc.
- Escape outputs: \`esc_html()\`, \`esc_url()\`, \`esc_attr()\`
- Use nonces for form security
- Hook everything — avoid direct execution in main file
CLAUDEEOF
  fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Workspace ready!"
echo ""
echo "  🌐 WordPress:   http://localhost:8080"
echo "  👤 Admin:       http://localhost:8080/wp-admin"
echo "     User: admin  Pass: admin"
echo "  💻 VS Code:     http://localhost:8081"
echo "  🗄️  phpMyAdmin:  http://localhost:8082"
echo ""
echo "  📂 Plugin dir:  $PLUGIN_DIR"
echo "  🤖 Claude Code: claude (in terminal)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
