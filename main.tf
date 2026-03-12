terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

provider "coder" {}
provider "docker" {}

# ── Parameters ──────────────────────────────────────────────────────────────

data "coder_parameter" "repo_url" {
  name         = "repo_url"
  display_name = "Plugin Repository URL"
  description  = "HTTPS or SSH URL of your existing plugin repo (e.g. https://github.com/org/my-plugin)"
  mutable      = true
}

data "coder_parameter" "repo_branch" {
  name         = "repo_branch"
  display_name = "Branch"
  description  = "Git branch to check out"
  default      = "main"
  mutable      = true
}

data "coder_parameter" "plugin_slug" {
  name         = "plugin_slug"
  display_name = "Plugin Slug"
  description  = "Folder name of the plugin inside wp-content/plugins/ (usually same as repo name)"
  default      = "my-wordpress-plugin"
  mutable      = true
}

data "coder_parameter" "php_version" {
  name         = "php_version"
  display_name = "PHP Version"
  description  = "PHP version to use"
  default      = "8.2"
  mutable      = false
  option {
    name  = "PHP 8.1"
    value = "8.1"
  }
  option {
    name  = "PHP 8.2"
    value = "8.2"
  }
  option {
    name  = "PHP 8.3"
    value = "8.3"
  }
}

data "coder_parameter" "wp_version" {
  name         = "wp_version"
  display_name = "WordPress Version"
  description  = "WordPress version to install"
  default      = "latest"
  mutable      = true
}

data "coder_parameter" "claude_code" {
  name         = "claude_code"
  display_name = "Install Claude Code"
  description  = "Install Claude Code CLI for AI-assisted development"
  default      = "true"
  mutable      = false
  option {
    name  = "Yes"
    value = "true"
  }
  option {
    name  = "No"
    value = "false"
  }
}

# ── Workspace ────────────────────────────────────────────────────────────────

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# ── Docker network ───────────────────────────────────────────────────────────

resource "docker_network" "wp_network" {
  name = "wp-${data.coder_workspace.me.id}"
}

# ── MySQL container ──────────────────────────────────────────────────────────

resource "docker_container" "mysql" {
  count   = data.coder_workspace.me.start_count
  image   = "mysql:8.0"
  name    = "mysql-${data.coder_workspace.me.id}"
  restart = "unless-stopped"

  networks_advanced {
    name = docker_network.wp_network.name
  }

  env = [
    "MYSQL_ROOT_PASSWORD=wordpress",
    "MYSQL_DATABASE=wordpress",
    "MYSQL_USER=wordpress",
    "MYSQL_PASSWORD=wordpress",
  ]

  volumes {
    volume_name    = docker_volume.mysql_data.name
    container_path = "/var/lib/mysql"
  }
}

resource "docker_volume" "mysql_data" {
  name = "mysql-data-${data.coder_workspace.me.id}"
}

# ── WordPress container ──────────────────────────────────────────────────────

resource "docker_container" "wordpress" {
  count   = data.coder_workspace.me.start_count
  image   = "wordpress:${data.coder_parameter.wp_version.value}-php${data.coder_parameter.php_version.value}-apache"
  name    = "wp-${data.coder_workspace.me.id}"
  restart = "unless-stopped"

  networks_advanced {
    name = docker_network.wp_network.name
  }

  env = [
    "WORDPRESS_DB_HOST=mysql-${data.coder_workspace.me.id}",
    "WORDPRESS_DB_USER=wordpress",
    "WORDPRESS_DB_PASSWORD=wordpress",
    "WORDPRESS_DB_NAME=wordpress",
    "WORDPRESS_DEBUG=1",
    "WORDPRESS_CONFIG_EXTRA=define('WP_DEBUG_LOG', true); define('WP_DEBUG_DISPLAY', false); define('SAVEQUERIES', true);",
  ]

  volumes {
    host_path      = "/home/${data.coder_workspace_owner.me.name}/workspace/plugin"
    container_path = "/var/www/html/wp-content/plugins/${data.coder_parameter.plugin_slug.value}"
  }

  ports {
    internal = 80
    external = 8080
  }
}

# ── Dev container ────────────────────────────────────────────────────────────

resource "docker_image" "dev" {
  name = "wp-dev-${data.coder_workspace.me.id}"
  build {
    context    = "${path.module}"
    dockerfile = "Dockerfile.dev"
    build_args = {
      PHP_VERSION    = data.coder_parameter.php_version.value
      CLAUDE_CODE    = data.coder_parameter.claude_code.value
    }
  }
  triggers = {
    dockerfile = filemd5("${path.module}/Dockerfile.dev")
  }
}

resource "docker_container" "dev" {
  count   = data.coder_workspace.me.start_count
  image   = docker_image.dev.image_id
  name    = "dev-${data.coder_workspace.me.id}"
  restart = "unless-stopped"

  networks_advanced {
    name = docker_network.wp_network.name
  }

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    "PLUGIN_REPO_URL=${data.coder_parameter.repo_url.value}",
    "PLUGIN_REPO_BRANCH=${data.coder_parameter.repo_branch.value}",
    "PLUGIN_SLUG=${data.coder_parameter.plugin_slug.value}",
    "WP_HOST=wp-${data.coder_workspace.me.id}",
    # Anthropic auth token — set in Coder Secrets as ANTHROPIC_TOKEN
    "ANTHROPIC_TOKEN=$ANTHROPIC_TOKEN",
    # Git token for private repos — set in Coder Secrets as GIT_TOKEN
    "GIT_TOKEN=$GIT_TOKEN",
  ]

  volumes {
    host_path      = "/home/${data.coder_workspace_owner.me.name}/workspace"
    container_path = "/home/coder/workspace"
  }

  command = ["/bin/bash", "-c", coder_agent.main.init_script]
}

resource "docker_volume" "workspace" {
  name = "workspace-${data.coder_workspace.me.id}"
}

# ── Coder agent ──────────────────────────────────────────────────────────────

resource "coder_agent" "main" {
  arch           = "amd64"
  os             = "linux"
  startup_script = <<-EOT
#!/usr/bin/env bash
set -euo pipefail

PLUGIN_SLUG="$${PLUGIN_SLUG:-my-wordpress-plugin}"
PLUGIN_REPO_URL="$${PLUGIN_REPO_URL:-}"
PLUGIN_REPO_BRANCH="$${PLUGIN_REPO_BRANCH:-main}"
WORKSPACE="/home/coder/workspace"
PLUGIN_DIR="$WORKSPACE/plugin"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  WordPress Plugin Dev Workspace"
echo "  Repo:   $PLUGIN_REPO_URL"
echo "  Branch: $PLUGIN_REPO_BRANCH"
echo "  Slug:   $PLUGIN_SLUG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

mkdir -p "$WORKSPACE"

# ── Git credentials for private repos ────────────────────────────────────────
if [ -n "$${GIT_TOKEN:-}" ]; then
  git config --global credential.helper store
  GIT_HOST=$(echo "$PLUGIN_REPO_URL" | sed -E 's|https://([^/]+)/.*|\1|')
  echo "https://oauth2:$${GIT_TOKEN}@$${GIT_HOST}" > ~/.git-credentials
  chmod 600 ~/.git-credentials
  echo "🔑 Git credentials configured for $GIT_HOST"
fi

git config --global user.email "dev@coder.local"
git config --global user.name "Coder Dev"

# ── Clone or update the plugin repo ──────────────────────────────────────────
if [ -z "$PLUGIN_REPO_URL" ]; then
  echo "❌ PLUGIN_REPO_URL is not set. Set it in workspace parameters."
  exit 1
fi

if [ -d "$PLUGIN_DIR/.git" ]; then
  echo "🔄 Plugin repo exists — pulling latest ($PLUGIN_REPO_BRANCH)..."
  cd "$PLUGIN_DIR"
  git fetch origin
  git checkout "$PLUGIN_REPO_BRANCH"
  git pull origin "$PLUGIN_REPO_BRANCH"
  echo "✅ Repo updated"
else
  echo "📥 Cloning $PLUGIN_REPO_URL ($PLUGIN_REPO_BRANCH)..."
  git clone \
    --branch "$PLUGIN_REPO_BRANCH" \
    --single-branch \
    "$PLUGIN_REPO_URL" \
    "$PLUGIN_DIR"
  echo "✅ Repo cloned to $PLUGIN_DIR"
fi

# ── Detect plugin metadata from main plugin file ──────────────────────────────
MAIN_PHP=$(find "$PLUGIN_DIR" -maxdepth 1 -name "*.php" \
  -exec grep -l "Plugin Name:" {} \; | head -1 || true)

if [ -n "$MAIN_PHP" ]; then
  PLUGIN_NAME=$(grep -i "Plugin Name:" "$MAIN_PHP" | sed 's/.*Plugin Name:[[:space:]]*//' | tr -d '\r')
  PLUGIN_VERSION=$(grep -i "^.*Version:" "$MAIN_PHP" | head -1 | sed 's/.*Version:[[:space:]]*//' | tr -d '\r')
  echo "📋 Detected: $PLUGIN_NAME v$${PLUGIN_VERSION:-unknown}"
else
  PLUGIN_NAME="$PLUGIN_SLUG"
fi

# ── Install Composer dependencies ─────────────────────────────────────────────
if [ -f "$PLUGIN_DIR/composer.json" ]; then
  echo "📦 Installing Composer dependencies..."
  cd "$PLUGIN_DIR" && composer install --no-interaction --prefer-dist 2>&1 | tail -5
fi

# ── Install npm dependencies ──────────────────────────────────────────────────
if [ -f "$PLUGIN_DIR/package.json" ]; then
  echo "📦 Installing npm dependencies..."
  cd "$PLUGIN_DIR" && npm install --silent
fi

# ── Wait for MySQL ────────────────────────────────────────────────────────────
echo "⏳ Waiting for MySQL..."
until mysqladmin ping -h"$${WP_HOST:-localhost}" --silent 2>/dev/null; do
  sleep 2
done
echo "✅ MySQL ready"

# ── Wait for WordPress ────────────────────────────────────────────────────────
echo "⏳ Waiting for WordPress..."
sleep 5

# ── Configure WP-CLI ─────────────────────────────────────────────────────────
mkdir -p ~/.wp-cli
cat > ~/.wp-cli/config.yml <<EOF
path: /var/www/html
url: http://localhost:8080
user: admin
EOF

# ── Install WordPress ─────────────────────────────────────────────────────────
echo "⚙️  Configuring WordPress..."
wp --path=/var/www/html core install \
  --url="http://localhost:8080" \
  --title="Dev — $${PLUGIN_NAME}" \
  --admin_user=admin \
  --admin_password=admin \
  --admin_email=dev@local.test \
  --skip-email 2>/dev/null || echo "ℹ️  WordPress already installed"

# Symlink plugin into wp-content/plugins if not mounted
WP_PLUGIN_DIR="/var/www/html/wp-content/plugins/$PLUGIN_SLUG"
if [ ! -e "$WP_PLUGIN_DIR" ]; then
  ln -sf "$PLUGIN_DIR" "$WP_PLUGIN_DIR"
  echo "🔗 Symlinked plugin → $WP_PLUGIN_DIR"
fi

wp --path=/var/www/html plugin activate "$PLUGIN_SLUG" 2>/dev/null \
  && echo "✅ Plugin activated" \
  || echo "⚠️  Plugin activation failed — check PHP errors"

# ── Anthropic auth token for Claude Code ─────────────────────────────────────
if [ -n "$${ANTHROPIC_TOKEN:-}" ]; then
  mkdir -p ~/.config/anthropic
  cat > ~/.config/anthropic/auth.json <<AUTHEOF
{
  "type": "token",
  "token": "$${ANTHROPIC_TOKEN}"
}
AUTHEOF
  chmod 600 ~/.config/anthropic/auth.json
  echo "🔑 Anthropic auth token configured"
fi

# ── Generate CLAUDE.md for the existing plugin ───────────────────────────────
if command -v claude &>/dev/null && [ ! -f "$PLUGIN_DIR/CLAUDE.md" ]; then
  echo "🤖 Generating CLAUDE.md project context..."

  HAS_COMPOSER=$([ -f "$PLUGIN_DIR/composer.json" ] && echo "yes" || echo "no")
  HAS_NPM=$([ -f "$PLUGIN_DIR/package.json" ] && echo "yes" || echo "no")
  HAS_TESTS=$([ -d "$PLUGIN_DIR/tests" ] && echo "yes" || echo "no")
  WP_VERSION=$(wp --path=/var/www/html core version 2>/dev/null || echo "latest")
  PHP_VER=$(php -r "echo PHP_VERSION;")

  # Compact directory tree (no vendor/node_modules/.git)
  TREE=$(find "$PLUGIN_DIR" -maxdepth 3 \
    -not -path "*/vendor/*" \
    -not -path "*/node_modules/*" \
    -not -path "*/.git/*" \
    -not -path "*/build/*" \
    | sed "s|$PLUGIN_DIR/||" | sort | head -50)

  cat > "$PLUGIN_DIR/CLAUDE.md" <<CLAUDEEOF
# Claude Code — Project Context

## Plugin
- **Name**: $${PLUGIN_NAME}
- **Slug**: $${PLUGIN_SLUG}
- **Repo**: $${PLUGIN_REPO_URL}  (branch: \`$${PLUGIN_REPO_BRANCH}\`)
- **Main file**: $(basename "$${MAIN_PHP:-$PLUGIN_SLUG.php}")

## Environment
- PHP $${PHP_VER} + WordPress $${WP_VERSION}
- Composer: $${HAS_COMPOSER}  |  npm / @wordpress/scripts: $${HAS_NPM}  |  PHPUnit: $${HAS_TESTS}
- Live site: http://localhost:8080
- Debug log: /var/www/html/wp-content/debug.log

## Directory Tree
\`\`\`
$${TREE}
\`\`\`

## Common Commands
$([ "$HAS_COMPOSER" = "yes" ] && printf '- `composer install`   — PHP dependencies\n- `composer test`      — run PHPUnit\n- `composer lint`      — WordPress Coding Standards')
$([ "$HAS_NPM" = "yes" ] && printf '\n- `npm run build`      — production JS/CSS build\n- `npm run start`      — watch + rebuild')
- \`wp plugin list\`    — list active plugins
- \`wp option get $${PLUGIN_SLUG}_settings\`
- \`tail -f /var/www/html/wp-content/debug.log\`

## WordPress Security Checklist
- Sanitize inputs: \`sanitize_text_field()\`, \`absint()\`, \`wp_unslash()\`
- Escape outputs: \`esc_html()\`, \`esc_url()\`, \`esc_attr()\`
- Nonces on all forms and AJAX: \`check_admin_referer()\` / \`check_ajax_referer()\`
- Use \`\$wpdb->prepare()\` for all custom SQL
CLAUDEEOF

  echo "✅ CLAUDE.md written"
elif [ -f "$PLUGIN_DIR/CLAUDE.md" ]; then
  echo "ℹ️  CLAUDE.md already exists — skipping generation"
fi

# ── Start code-server (open plugin folder directly) ───────────────────────────
echo "🚀 Starting VS Code server..."
code-server \
  --bind-addr 0.0.0.0:8081 \
  --auth none \
  --disable-telemetry \
  "$PLUGIN_DIR" &

# ── Start phpMyAdmin ──────────────────────────────────────────────────────────
echo "🚀 Starting phpMyAdmin..."
cat > /opt/phpmyadmin/config.inc.php <<PMAEOF
<?php
\$cfg['Servers'][1]['host']      = getenv('WP_HOST') ?: 'localhost';
\$cfg['Servers'][1]['user']      = 'wordpress';
\$cfg['Servers'][1]['password']  = 'wordpress';
\$cfg['Servers'][1]['auth_type'] = 'config';
\$cfg['blowfish_secret']         = 'coder-dev-secret-change-me';
PMAEOF
php -S 0.0.0.0:8082 -t /opt/phpmyadmin/ &>/tmp/phpmyadmin.log &

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Workspace ready!"
echo ""
echo "  🌐 WordPress:   http://localhost:8080"
echo "  👤 WP Admin:    http://localhost:8080/wp-admin  (admin / admin)"
echo "  💻 VS Code:     http://localhost:8081"
echo "  🗄️  phpMyAdmin:  http://localhost:8082"
echo ""
echo "  📂 Plugin:      $PLUGIN_DIR"
echo "  🔌 Active:      $PLUGIN_SLUG"
echo "  🌿 Branch:      $PLUGIN_REPO_BRANCH"
echo ""
echo "  🤖 Claude Code (auth token ready):"
echo "     claude                             # interactive session"
echo "     claude 'explain this plugin'       # one-shot"
echo "     claude 'add a REST API endpoint'   # build features"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  EOT

  metadata {
    display_name = "PHP Version"
    key          = "php_version"
    script       = "php --version | head -1"
    interval     = 60
    timeout      = 5
  }

  metadata {
    display_name = "WP-CLI Version"
    key          = "wpcli_version"
    script       = "wp --version 2>/dev/null || echo 'not ready'"
    interval     = 60
    timeout      = 5
  }

  metadata {
    display_name = "Plugin Tests"
    key          = "test_status"
    script       = "cd ~/workspace/plugin && composer test 2>&1 | tail -1 || echo 'no tests yet'"
    interval     = 120
    timeout      = 30
  }
}

# ── Apps ─────────────────────────────────────────────────────────────────────

resource "coder_app" "wordpress" {
  agent_id     = coder_agent.main.id
  slug         = "wordpress"
  display_name = "WordPress Site"
  url          = "http://localhost:8080"
  icon         = "/icon/wordpress.svg"
  share        = "owner"
  subdomain    = true
}

resource "coder_app" "code_server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "VS Code (Browser)"
  url          = "http://localhost:8081?folder=/home/coder/workspace"
  icon         = "/icon/code.svg"
  share        = "owner"
  subdomain    = true
}

resource "coder_app" "phpmyadmin" {
  agent_id     = coder_agent.main.id
  slug         = "phpmyadmin"
  display_name = "phpMyAdmin"
  url          = "http://localhost:8082"
  icon         = "/icon/database.svg"
  share        = "owner"
  subdomain    = true
}
