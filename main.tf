terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.13.0"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "coder" {}
provider "docker" {}

# ── Variables (secrets — set at template level) ──────────────────────────────

variable "git_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Git personal access token for cloning private repos"
}

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
  default      = "http://178.104.53.153:3000"
  mutable      = true
}

data "coder_parameter" "agent_arch" {
  name         = "agent_arch"
  display_name = "Agent Architecture"
  default      = "amd64"
  mutable      = false
  option {
    name  = "amd64 (Intel/AMD)"
    value = "amd64"
  }
  option {
    name  = "arm64 (Graviton)"
    value = "arm64"
  }
}

data "coder_parameter" "php_version" {
  name         = "php_version"
  display_name = "PHP Version"
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
  default      = "latest"
  mutable      = true
}

# ── Workspace ────────────────────────────────────────────────────────────────

data "coder_workspace"       "me" {}
data "coder_workspace_owner" "me" {}

# ── Random secret for phpMyAdmin ─────────────────────────────────────────────

resource "random_string" "blowfish_secret" {
  length  = 32
  special = false
}

# ── Docker network ────────────────────────────────────────────────────────────

resource "docker_network" "wp_network" {
  name     = "wp-${data.coder_workspace.me.id}"
  ipv6     = false
  internal = false
}

# ── MySQL ─────────────────────────────────────────────────────────────────────

resource "docker_volume" "claude_config" {
  name = "claude-config-${data.coder_workspace.me.id}"
}

resource "docker_volume" "mysql_data" {
  name = "mysql-data-${data.coder_workspace.me.id}"
}

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
}

# ── Dev container ─────────────────────────────────────────────────────────────

resource "docker_image" "dev" {
  name = "wp-dev-${data.coder_workspace.me.id}"
  build {
    context    = path.module
    dockerfile = "Dockerfile.dev"
    build_args = {
      PHP_VERSION = data.coder_parameter.php_version.value
    }
  }
  triggers = {
    dockerfile  = filemd5("${path.module}/Dockerfile.dev")
    php_version = data.coder_parameter.php_version.value
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
    "CODER_AGENT_URL=${data.coder_parameter.coder_access_url.value}",
    "PLUGINS_JSON_B64=${base64encode(data.coder_parameter.plugins.value)}",
    "WP_HOST=wp-${data.coder_workspace.me.id}",
    "MYSQL_HOST=mysql-${data.coder_workspace.me.id}",
    "GIT_TOKEN=${var.git_token}",
    "BLOWFISH_SECRET=${random_string.blowfish_secret.result}",
  ]

  volumes {
    host_path      = data.coder_parameter.plugins_base_path.value
    container_path = "/home/coder/workspace"
  }

  # Claude Code config — persist login across restarts
  volumes {
    volume_name    = docker_volume.claude_config.name
    container_path = "/home/coder/.claude"
  }

  # Docker socket — needed for WP-CLI ssh:docker: transport
  volumes {
    host_path      = "/var/run/docker.sock"
    container_path = "/var/run/docker.sock"
  }

  command = ["/bin/bash", "-c", coder_agent.main.init_script]
}

# ── Coder agent ───────────────────────────────────────────────────────────────

resource "coder_agent" "main" {
  arch = data.coder_parameter.agent_arch.value
  os   = "linux"
  dir  = "/home/coder/workspace"

  startup_script = <<-EOT
#!/usr/bin/env bash
# NO set -e — script must survive errors or agent disconnects
set -uo pipefail

WORKSPACE="/home/coder/workspace"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  WordPress Multi-Plugin Dev Workspace"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Step 0: Start socat IPv4 proxy for WordPress container
# Docker embedded DNS returns AAAA (IPv6) records for container hostnames,
# but Apache only listens on IPv4 — causing 502 "connection refused" errors.
# socat explicitly connects over TCP4, bypassing DNS IPv6 entirely.
WP_CONTAINER="$${WP_HOST:-localhost}"
if [ "$WP_CONTAINER" != "localhost" ]; then
  echo "Starting IPv4 proxy for WordPress ($WP_CONTAINER)..."
  for attempt in $(seq 1 30); do
    WP_IPV4=$(getent ahostsv4 "$WP_CONTAINER" 2>/dev/null | awk 'NR==1{print $1}')
    if [ -n "$WP_IPV4" ]; then
      echo "Resolved $WP_CONTAINER -> $WP_IPV4"
      socat TCP-LISTEN:8080,bind=127.0.0.1,fork,reuseaddr TCP4:$${WP_IPV4}:80 >/dev/null 2>&1 &
      echo "WordPress proxy: 127.0.0.1:8080 -> $${WP_IPV4}:80"
      break
    fi
    sleep 2
  done
fi

# Step 0b: Fix permissions on workspace volume (mounted as root)
sudo chown -R coder:coder "$WORKSPACE" 2>/dev/null || true
sudo chown -R coder:coder /home/coder/.claude 2>/dev/null || true

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

# Step 4: Process each plugin — clone if missing, then install deps
SLUGS=()
if [ "$PLUGIN_COUNT" -gt 0 ]; then
  for i in $(seq 0 $((PLUGIN_COUNT - 1))); do
    SLUG=$(echo "$PLUGINS_JSON" | jq -r ".[$i].slug // empty")
    [ -z "$SLUG" ] && continue
    URL=$(echo "$PLUGINS_JSON" | jq -r ".[$i].url // empty")
    BRANCH=$(echo "$PLUGINS_JSON" | jq -r ".[$i].branch // \"main\"")
    DIR="$WORKSPACE/$SLUG"
    SLUGS+=("$SLUG")
    echo ""
    echo "── $SLUG ──────────────────────────────────────────"

    # Clone the repo if directory doesn't exist or is empty
    if [ ! -d "$DIR/.git" ]; then
      if [ -n "$URL" ]; then
        echo "  Cloning $URL (branch: $BRANCH)..."
        git clone --branch "$BRANCH" --single-branch "$URL" "$DIR" 2>&1 | tail -3 || {
          echo "  FAILED to clone $URL"
          continue
        }
        echo "  Cloned successfully"
      else
        echo "  WARNING: No URL provided for $SLUG, skipping"
        continue
      fi
    else
      # Already cloned — pull latest
      CUR_BRANCH=$(git -C "$DIR" branch --show-current 2>/dev/null || echo "detached")
      echo "  Pulling latest on $CUR_BRANCH..."
      git -C "$DIR" pull --ff-only 2>&1 | tail -3 || echo "  Pull failed (may have local changes)"
      COMMIT=$(git -C "$DIR" log --oneline -1 2>/dev/null || echo "unknown")
      echo "  Branch: $CUR_BRANCH | $COMMIT"
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
echo "Waiting for MySQL ($${MYSQL_HOST:-localhost})..."
T=0
until mysqladmin ping -h"$${MYSQL_HOST:-localhost}" -u wordpress -pwordpress --silent 2>/dev/null; do
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

# Step 7: WP-CLI config — run commands inside the WordPress container via Docker
# Requires Docker socket mounted into the dev container
mkdir -p ~/.wp-cli
cat > ~/.wp-cli/config.yml <<WPCLIEOF
ssh: docker:$${WP_HOST:-localhost}
path: /var/www/html
url: http://127.0.0.1:8080
user: admin
WPCLIEOF
# Ensure coder user can access Docker socket
sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

# Step 8: Install WordPress via WP-CLI over the WordPress container
wp core is-installed 2>/dev/null \
  && echo "WordPress already installed" \
  || {
    wp core install \
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
    wp plugin activate "$SLUG" 2>/dev/null \
      && echo "  OK: $SLUG" \
      || echo "  FAILED: $SLUG"
  done
fi

# Step 10: CLAUDE.md
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

# Step 11: Start VS Code — bind to 127.0.0.1 (agent-local, IPv4 only)
echo "Starting VS Code..."
code-server \
  --bind-addr 127.0.0.1:8081 \
  --auth none \
  --disable-telemetry \
  "$WORKSPACE" >/tmp/code-server.log 2>&1 &

# Step 12: Start phpMyAdmin — bind to 127.0.0.1
echo "Starting phpMyAdmin..."
sudo tee /opt/phpmyadmin/config.inc.php >/dev/null <<PMAEOF
<?php
\$cfg['Servers'][1]['host']      = getenv('WP_HOST') ?: 'localhost';
\$cfg['Servers'][1]['user']      = 'wordpress';
\$cfg['Servers'][1]['password']  = 'wordpress';
\$cfg['Servers'][1]['auth_type'] = 'config';
\$cfg['blowfish_secret']         = '$${BLOWFISH_SECRET:-coder-dev-fallback-secret}';
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
    script       = "wp plugin list --status=active --field=name 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo 'not ready'"
    interval     = 60
    timeout      = 10
  }
}

# ── Apps ──────────────────────────────────────────────────────────────────────

resource "coder_app" "wordpress" {
  agent_id     = coder_agent.main.id
  slug         = "wordpress"
  display_name = "WordPress"
  # Local socat proxy — forwards to WordPress container over IPv4 only
  url          = "http://127.0.0.1:8080"
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
