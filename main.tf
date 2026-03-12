terraform {
  required_providers {
    coder  = { source = "coder/coder" }
    docker = { source = "kreuzwerker/docker" }
  }
}

provider "coder" {}
provider "docker" {}

# ── Parameters ───────────────────────────────────────────────────────────────

data "coder_parameter" "plugins" {
  name         = "plugins"
  display_name = "Plugins (JSON)"
  description  = "JSON array: [{\"slug\":\"my-plugin\",\"url\":\"https://github.com/org/repo\",\"branch\":\"main\"}]"
  default = jsonencode([{
    url    = "https://github.com/your-org/plugin-one"
    slug   = "plugin-one"
    branch = "main"
  }])
  mutable = true
}

data "coder_parameter" "plugins_base_path" {
  name         = "plugins_base_path"
  display_name = "Plugins Base Path (Host)"
  description  = "Absolute path on Coder server where plugin repos are cloned"
  default      = "/home/ubuntu/plugins"
  mutable      = true
}

data "coder_parameter" "coder_access_url" {
  name         = "coder_access_url"
  display_name = "Coder Access URL"
  description  = "URL containers use to reach Coder — use your Hetzner public IP, not localhost"
  default      = "http://172.17.0.1:3000"
  mutable      = true
}

data "coder_parameter" "agent_arch" {
  name         = "agent_arch"
  display_name = "Agent Architecture"
  default      = "amd64"
  mutable      = false
  option { name = "amd64 (Intel/AMD)" value = "amd64" }
  option { name = "arm64 (Graviton)"  value = "arm64" }
}

data "coder_parameter" "php_version" {
  name         = "php_version"
  display_name = "PHP Version"
  default      = "8.2"
  mutable      = false
  option { name = "PHP 8.1" value = "8.1" }
  option { name = "PHP 8.2" value = "8.2" }
  option { name = "PHP 8.3" value = "8.3" }
}

data "coder_parameter" "wp_version" {
  name         = "wp_version"
  display_name = "WordPress Version"
  default      = "latest"
  mutable      = true
}

data "coder_parameter" "claude_code" {
  name         = "claude_code"
  display_name = "Install Claude Code"
  default      = "true"
  mutable      = false
  option { name = "Yes" value = "true"  }
  option { name = "No"  value = "false" }
}

# ── Workspace ────────────────────────────────────────────────────────────────

data "coder_workspace"       "me" {}
data "coder_workspace_owner" "me" {}

# ── Docker network ────────────────────────────────────────────────────────────

resource "docker_network" "wp_network" {
  name = "wp-${data.coder_workspace.me.id}"
}

# ── MySQL ─────────────────────────────────────────────────────────────────────

resource "docker_volume" "mysql_data" {
  name = "mysql-data-${data.coder_workspace.me.id}"
}

resource "docker_container" "mysql" {
  count   = data.coder_workspace.me.start_count
  image   = "mysql:8.0"
  name    = "mysql-${data.coder_workspace.me.id}"
  restart = "unless-stopped"

  networks_advanced { name = docker_network.wp_network.name }

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

# ── WordPress ─────────────────────────────────────────────────────────────────

resource "docker_container" "wordpress" {
  count = data.coder_workspace.me.start_count
  image = (
    data.coder_parameter.wp_version.value == "latest"
    ? "wordpress:php${data.coder_parameter.php_version.value}-apache"
    : "wordpress:${data.coder_parameter.wp_version.value}-php${data.coder_parameter.php_version.value}-apache"
  )
  name    = "wp-${data.coder_workspace.me.id}"
  restart = "unless-stopped"

  networks_advanced {
    name    = docker_network.wp_network.name
    aliases = ["wordpress-internal"]
  }

  env = [
    "WORDPRESS_DB_HOST=mysql-${data.coder_workspace.me.id}",
    "WORDPRESS_DB_USER=wordpress",
    "WORDPRESS_DB_PASSWORD=wordpress",
    "WORDPRESS_DB_NAME=wordpress",
    "WORDPRESS_DEBUG=1",
    "WORDPRESS_CONFIG_EXTRA=define('WP_DEBUG_LOG', true); define('WP_DEBUG_DISPLAY', false); define('SAVEQUERIES', true);",
  ]

  # Mount each plugin from host into wp-content/plugins/
  dynamic "volumes" {
    for_each = jsondecode(data.coder_parameter.plugins.value)
    content {
      host_path      = "${data.coder_parameter.plugins_base_path.value}/${volumes.value.slug}"
      container_path = "/var/www/html/wp-content/plugins/${volumes.value.slug}"
    }
  }

  # Explicitly bind to IPv4 — avoids Coder proxy 502 IPv6 errors on Hetzner
  ports {
    internal = 80
    external = 8080
    ip       = "0.0.0.0"
  }
}

# ── Dev container ─────────────────────────────────────────────────────────────

resource "docker_image" "dev" {
  name = "wp-dev-${data.coder_workspace.me.id}"
  build {
    context    = path.module
    dockerfile = "Dockerfile.dev"
    build_args = {
      PHP_VERSION = data.coder_parameter.php_version.value
      CLAUDE_CODE = data.coder_parameter.claude_code.value
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

  networks_advanced { name = docker_network.wp_network.name }

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    "CODER_AGENT_URL=${data.coder_parameter.coder_access_url.value}",
    "PLUGINS_JSON_B64=${base64encode(data.coder_parameter.plugins.value)}",
    "WP_HOST=wp-${data.coder_workspace.me.id}",
    "ANTHROPIC_TOKEN=$ANTHROPIC_TOKEN",
    "GIT_TOKEN=$GIT_TOKEN",
  ]

  volumes {
    host_path      = data.coder_parameter.plugins_base_path.value
    container_path = "/home/coder/workspace"
  }

  command = ["/bin/bash", "-c", coder_agent.main.init_script]
}

# ── Coder agent ───────────────────────────────────────────────────────────────

resource "coder_agent" "main" {
  arch = data.coder_parameter.agent_arch.value
  os   = "linux"

  startup_script = <<-EOT
#!/usr/bin/env bash
# NO set -e — script must survive errors or agent disconnects
set -uo pipefail

WORKSPACE="/home/coder/workspace"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  WordPress Multi-Plugin Dev Workspace"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Step 1: Install jq FIRST before any JSON parsing
if ! command -v jq &>/dev/null; then
  echo "Installing jq..."
  sudo apt-get update -qq && sudo apt-get install -y jq -qq 2>/dev/null || true
fi
echo "jq: $(jq --version 2>/dev/null || echo NOT FOUND)"

# Step 2: Decode PLUGINS_JSON from base64 safely
RAW_B64="$${PLUGINS_JSON_B64:-W10=}"
PLUGINS_JSON=$(echo "$RAW_B64" | base64 --decode 2>/dev/null \
            || echo "$RAW_B64" | base64 -d  2>/dev/null \
            || echo "[]")

if ! echo "$PLUGINS_JSON" | jq empty 2>/dev/null; then
  echo "WARNING: PLUGINS_JSON invalid, defaulting to []"
  PLUGINS_JSON="[]"
fi

PLUGIN_COUNT=$(echo "$PLUGINS_JSON" | jq 'length')
echo "$PLUGIN_COUNT plugin(s) configured"

# Step 3: Git config
git config --global user.email "dev@coder.local"
git config --global user.name  "Coder Dev"

if [ -n "$${GIT_TOKEN:-}" ]; then
  git config --global credential.helper store
  echo "$PLUGINS_JSON" | jq -r '.[].url // empty' 2>/dev/null \
    | sed -E 's|https://([^/]+)/.*|\1|' | sort -u \
    | while read -r H; do
        echo "https://oauth2:$${GIT_TOKEN}@$${H}" >> ~/.git-credentials
      done
  chmod 600 ~/.git-credentials 2>/dev/null || true
  echo "Git credentials configured"
fi

# Step 4: Process each plugin
SLUGS=()
if [ "$PLUGIN_COUNT" -gt 0 ]; then
  for i in $(seq 0 $((PLUGIN_COUNT - 1))); do
    SLUG=$(echo "$PLUGINS_JSON" | jq -r ".[$i].slug // empty")
    [ -z "$SLUG" ] && continue
    DIR="$WORKSPACE/$SLUG"
    SLUGS+=("$SLUG")
    echo ""
    echo "── $SLUG ──────────────────────────────────────────"
    if [ ! -d "$DIR" ]; then
      echo "  WARNING: $DIR not found on host"
      echo "  Run: cd $(dirname $DIR) && git clone <url> $SLUG"
      continue
    fi
    if [ -d "$DIR/.git" ]; then
      BRANCH=$(git -C "$DIR" branch --show-current 2>/dev/null || echo "detached")
      COMMIT=$(git -C "$DIR" log --oneline -1 2>/dev/null || echo "unknown")
      echo "  Branch: $BRANCH | $COMMIT"
    fi
    if [ -f "$DIR/composer.json" ]; then
      echo "  composer install..."
      (cd "$DIR" && composer install --no-interaction --prefer-dist -q 2>&1 | tail -3) || true
    fi
    if [ -f "$DIR/package.json" ]; then
      echo "  npm install..."
      (cd "$DIR" && npm install --silent 2>&1 | tail -3) || true
    fi
    echo "  OK: $SLUG"
  done
fi

# Step 5: Wait for MySQL
echo ""
echo "Waiting for MySQL ($${WP_HOST:-localhost})..."
T=0
until mysqladmin ping -h"$${WP_HOST:-localhost}" -u wordpress -pwordpress --silent 2>/dev/null; do
  T=$((T+1)); [ $T -ge 30 ] && echo "MySQL timeout" && break; sleep 3
done
echo "MySQL ready"

# Step 6: Wait for WordPress
echo "Waiting for WordPress..."
T=0
until curl -sf "http://$${WP_HOST:-localhost}:80/" -o /dev/null 2>/dev/null; do
  T=$((T+1)); [ $T -ge 20 ] && echo "WordPress timeout" && break; sleep 3
done
echo "WordPress responding"

# Step 7: WP-CLI config — NO leading spaces in YAML
mkdir -p ~/.wp-cli
cat > ~/.wp-cli/config.yml <<WPCLIEOF
path: /var/www/html
url: http://localhost:8080
user: admin
WPCLIEOF

# Step 8: Install WordPress
wp --path=/var/www/html core is-installed 2>/dev/null \
  && echo "WordPress already installed" \
  || {
    wp --path=/var/www/html core install \
      --url="http://localhost:8080" \
      --title="Multi-Plugin Dev" \
      --admin_user=admin \
      --admin_password=admin \
      --admin_email=dev@local.test \
      --skip-email 2>/dev/null && echo "WordPress installed"
  }

# Step 9: Activate plugins
if [ "$${#SLUGS[@]}" -gt 0 ]; then
  echo "Activating plugins..."
  for SLUG in "$${SLUGS[@]}"; do
    wp --path=/var/www/html plugin activate "$SLUG" 2>/dev/null \
      && echo "  OK: $SLUG" \
      || echo "  FAILED: $SLUG"
  done
fi

# Step 10: Anthropic auth — heredoc at column 0, no indent
if [ -n "$${ANTHROPIC_TOKEN:-}" ]; then
  mkdir -p ~/.config/anthropic
cat > ~/.config/anthropic/auth.json <<AUTHEOF
{
  "type": "token",
  "token": "$${ANTHROPIC_TOKEN}"
}
AUTHEOF
  chmod 600 ~/.config/anthropic/auth.json
  echo "Anthropic token configured"
fi

# Step 11: CLAUDE.md
CLAUDE_MD="$WORKSPACE/CLAUDE.md"
if [ ! -f "$CLAUDE_MD" ] && [ "$PLUGIN_COUNT" -gt 0 ]; then
  {
    echo "# Claude Code - Multi-Plugin Workspace"
    echo ""
    for i in $(seq 0 $((PLUGIN_COUNT - 1))); do
      SLUG=$(echo "$PLUGINS_JSON" | jq -r ".[$i].slug   // empty")
      URL=$(echo  "$PLUGINS_JSON" | jq -r ".[$i].url    // \"(local)\"")
      BR=$(echo   "$PLUGINS_JSON" | jq -r ".[$i].branch // \"main\"")
      DIR="$WORKSPACE/$SLUG"
      MAIN=$(find "$DIR" -maxdepth 1 -name "*.php" -exec grep -l "Plugin Name:" {} \; 2>/dev/null | head -1 || true)
      NAME=$([ -n "$MAIN" ] && grep -i "Plugin Name:" "$MAIN" | sed 's/.*Plugin Name:[[:space:]]*//' | tr -d '\r' || echo "$SLUG")
      echo "## $NAME ($SLUG)"
      echo "- Repo: $URL branch: $BR"
      echo "- Dir: $DIR"
      echo "- composer: $([ -f "$DIR/composer.json" ] && echo yes || echo no) | npm: $([ -f "$DIR/package.json" ] && echo yes || echo no)"
      echo ""
    done
    echo "## Commands"
    echo '```'
    echo "wp plugin list"
    echo "wp cache flush"
    echo "tail -f /var/www/html/wp-content/debug.log"
    echo "git add . && git commit -m 'feat:' && git push"
    echo '```'
  } > "$CLAUDE_MD"
  echo "CLAUDE.md generated"
fi

# Step 12: Start VS Code — bind to 127.0.0.1 (agent-local, IPv4 only)
echo "Starting VS Code..."
code-server \
  --bind-addr 127.0.0.1:8081 \
  --auth none \
  --disable-telemetry \
  "$WORKSPACE" >/tmp/code-server.log 2>&1 &

# Step 13: Start phpMyAdmin — bind to 127.0.0.1, heredoc at column 0
echo "Starting phpMyAdmin..."
cat > /opt/phpmyadmin/config.inc.php <<PMAEOF
<?php
\$cfg['Servers'][1]['host']      = getenv('WP_HOST') ?: 'localhost';
\$cfg['Servers'][1]['user']      = 'wordpress';
\$cfg['Servers'][1]['password']  = 'wordpress';
\$cfg['Servers'][1]['auth_type'] = 'config';
\$cfg['blowfish_secret']         = 'coder-dev-secret-change-me';
PMAEOF
php -S 127.0.0.1:8082 -t /opt/phpmyadmin/ >/tmp/phpmyadmin.log 2>&1 &

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DONE — use app buttons in Coder dashboard"
echo "  WP Admin: admin / admin"
if [ "$${#SLUGS[@]}" -gt 0 ]; then
  for SLUG in "$${SLUGS[@]}"; do echo "  Plugin: ~/workspace/$SLUG"; done
fi
echo "  Claude: claude"
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
    display_name = "Active Plugins"
    key          = "active_plugins"
    script       = "wp --path=/var/www/html plugin list --status=active --field=name 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo 'not ready'"
    interval     = 60
    timeout      = 10
  }
}

# ── Apps ──────────────────────────────────────────────────────────────────────

resource "coder_app" "wordpress" {
  agent_id     = coder_agent.main.id
  slug         = "wordpress"
  display_name = "WordPress"
  # Use Docker container hostname — avoids IPv6 502 errors on Hetzner
  url          = "http://wp-${data.coder_workspace.me.id}:80"
  icon         = "/icon/wordpress.svg"
  share        = "owner"
  subdomain    = true
}

resource "coder_app" "code_server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "VS Code"
  url          = "http://127.0.0.1:8081?folder=/home/coder/workspace"
  icon         = "/icon/code.svg"
  share        = "owner"
  subdomain    = true
}

resource "coder_app" "phpmyadmin" {
  agent_id     = coder_agent.main.id
  slug         = "phpmyadmin"
  display_name = "phpMyAdmin"
  url          = "http://127.0.0.1:8082"
  icon         = "/icon/database.svg"
  share        = "owner"
  subdomain    = true
}
