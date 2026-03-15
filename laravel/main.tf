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

data "coder_parameter" "repo_url" {
  name         = "repo_url"
  display_name = "Git Repo URL"
  description  = "HTTPS URL of the Laravel project repository"
  default      = ""
  mutable      = true
}

data "coder_parameter" "repo_branch" {
  name         = "repo_branch"
  display_name = "Git Branch"
  description  = "Branch to clone/checkout"
  default      = "main"
  mutable      = true
}

data "coder_parameter" "project_base_path" {
  name         = "project_base_path"
  display_name = "Project Base Path (Host)"
  description  = "Absolute path on Coder server where the Laravel project is stored"
  default      = "/home/ubuntu/laravel-projects"
  mutable      = true
}

data "coder_parameter" "coder_access_url" {
  name         = "coder_access_url"
  display_name = "Coder Access URL"
  description  = "URL containers use to reach Coder — use your public IP, not localhost"
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

# ── Workspace ────────────────────────────────────────────────────────────────

data "coder_workspace"       "me" {}
data "coder_workspace_owner" "me" {}

# ── Random secret for phpMyAdmin ─────────────────────────────────────────────

resource "random_string" "blowfish_secret" {
  length  = 32
  special = false
}

# ── Docker network ────────────────────────────────────────────────────────────

resource "docker_network" "laravel_network" {
  name     = "laravel-${data.coder_workspace.me.id}"
  ipv6     = false
  internal = false
}

# ── Volumes ──────────────────────────────────────────────────────────────────

resource "docker_volume" "claude_config" {
  name = "claude-config-${data.coder_workspace.me.id}"
}

resource "docker_volume" "mysql_data" {
  name = "mysql-data-${data.coder_workspace.me.id}"
}

resource "docker_volume" "redis_data" {
  name = "redis-data-${data.coder_workspace.me.id}"
}

# ── MySQL ─────────────────────────────────────────────────────────────────────

resource "docker_container" "mysql" {
  count   = data.coder_workspace.me.start_count
  image   = "mysql:8.0"
  name    = "mysql-${data.coder_workspace.me.id}"
  restart = "unless-stopped"

  networks_advanced {
    name = docker_network.laravel_network.name
  }

  env = [
    "MYSQL_ROOT_PASSWORD=laravel",
    "MYSQL_DATABASE=laravel",
    "MYSQL_USER=laravel",
    "MYSQL_PASSWORD=laravel",
  ]

  volumes {
    volume_name    = docker_volume.mysql_data.name
    container_path = "/var/lib/mysql"
  }
}

# ── Redis ─────────────────────────────────────────────────────────────────────

resource "docker_container" "redis" {
  count   = data.coder_workspace.me.start_count
  image   = "redis:7-alpine"
  name    = "redis-${data.coder_workspace.me.id}"
  restart = "unless-stopped"

  networks_advanced {
    name = docker_network.laravel_network.name
  }

  volumes {
    volume_name    = docker_volume.redis_data.name
    container_path = "/data"
  }
}

# ── Dev container ─────────────────────────────────────────────────────────────

resource "docker_image" "dev" {
  name = "laravel-dev-${data.coder_workspace.me.id}"
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
    name = docker_network.laravel_network.name
  }

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    "CODER_AGENT_URL=${data.coder_parameter.coder_access_url.value}",
    "MYSQL_HOST=mysql-${data.coder_workspace.me.id}",
    "REDIS_HOST=redis-${data.coder_workspace.me.id}",
    "GIT_TOKEN=${var.git_token}",
    "REPO_URL=${data.coder_parameter.repo_url.value}",
    "REPO_BRANCH=${data.coder_parameter.repo_branch.value}",
    "BLOWFISH_SECRET=${random_string.blowfish_secret.result}",
  ]

  # Mount project from host path
  volumes {
    host_path      = data.coder_parameter.project_base_path.value
    container_path = "/home/coder/workspace"
  }

  # Claude Code config — persist login across restarts
  volumes {
    volume_name    = docker_volume.claude_config.name
    container_path = "/home/coder/.claude"
  }

  # Docker socket
  volumes {
    host_path      = "/var/run/docker.sock"
    container_path = "/var/run/docker.sock"
  }

  command = ["/bin/bash", "-c", "sudo chown coder:coder /home/coder && sudo chown -R coder:coder /home/coder/.claude 2>/dev/null; ${coder_agent.main.init_script}"]
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
echo "  Laravel Dev Workspace"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Step 0: Fix permissions on home + workspace volumes (mounted as root)
sudo chown coder:coder /home/coder 2>/dev/null || true
sudo chown -R coder:coder "$WORKSPACE" 2>/dev/null || true
sudo chown -R coder:coder /home/coder/.claude 2>/dev/null || true

# Step 1: Docker socket permissions
sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

# Step 2: Git config
git config --global user.email "dev@coder.local"
git config --global user.name  "Coder Dev"

if [ -n "$${GIT_TOKEN:-}" ]; then
  git config --global credential.helper store
  if [ -n "$${REPO_URL:-}" ]; then
    REPO_HOST=$(echo "$REPO_URL" | sed -E 's|https://([^/]+)/.*|\1|')
    echo "https://oauth2:$${GIT_TOKEN}@$${REPO_HOST}" >> ~/.git-credentials
  fi
  chmod 600 ~/.git-credentials 2>/dev/null || true
  echo "Git credentials configured"
fi

# Step 3: Clone repo if not exists
if [ -n "$${REPO_URL:-}" ] && [ ! -d "$WORKSPACE/.git" ]; then
  echo "Cloning $${REPO_URL} (branch: $${REPO_BRANCH:-main})..."
  # Clone into a temp dir, then move contents (workspace dir already exists as mount)
  TMPDIR=$(mktemp -d)
  git clone --branch "$${REPO_BRANCH:-main}" --single-branch "$REPO_URL" "$TMPDIR" 2>&1 | tail -5 || {
    echo "FAILED to clone $REPO_URL"
    rm -rf "$TMPDIR"
  }
  if [ -d "$TMPDIR/.git" ]; then
    shopt -s dotglob
    mv "$TMPDIR"/* "$WORKSPACE/" 2>/dev/null || true
    shopt -u dotglob
    rm -rf "$TMPDIR"
    echo "Cloned successfully"
  fi
elif [ -d "$WORKSPACE/.git" ]; then
  CUR_BRANCH=$(git -C "$WORKSPACE" branch --show-current 2>/dev/null || echo "detached")
  echo "Pulling latest on $CUR_BRANCH..."
  git -C "$WORKSPACE" pull --ff-only 2>&1 | tail -3 || echo "Pull failed (may have local changes)"
fi

# Step 4: Composer install
if [ -f "$WORKSPACE/composer.json" ]; then
  echo "Running composer install..."
  (cd "$WORKSPACE" && composer install --no-interaction --prefer-dist -q 2>&1 | tail -5) || true
fi

# Step 5: NPM install
if [ -f "$WORKSPACE/package.json" ]; then
  echo "Running npm install..."
  (cd "$WORKSPACE" && npm install --silent 2>&1 | tail -5) || true
fi

# Step 6: Laravel environment setup
if [ -f "$WORKSPACE/.env.example" ] && [ ! -f "$WORKSPACE/.env" ]; then
  echo "Copying .env.example to .env..."
  cp "$WORKSPACE/.env.example" "$WORKSPACE/.env"

  # Update .env with container hostnames
  sed -i "s|^DB_HOST=.*|DB_HOST=$${MYSQL_HOST}|"           "$WORKSPACE/.env"
  sed -i "s|^DB_DATABASE=.*|DB_DATABASE=laravel|"           "$WORKSPACE/.env"
  sed -i "s|^DB_USERNAME=.*|DB_USERNAME=laravel|"           "$WORKSPACE/.env"
  sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=laravel|"           "$WORKSPACE/.env"
  sed -i "s|^REDIS_HOST=.*|REDIS_HOST=$${REDIS_HOST}|"     "$WORKSPACE/.env"
  sed -i "s|^CACHE_DRIVER=.*|CACHE_DRIVER=redis|"          "$WORKSPACE/.env" 2>/dev/null || true
  sed -i "s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|"      "$WORKSPACE/.env" 2>/dev/null || true

  echo ".env configured"
fi

# Step 7: Generate app key if missing
if [ -f "$WORKSPACE/artisan" ]; then
  APP_KEY=$(grep "^APP_KEY=" "$WORKSPACE/.env" 2>/dev/null | cut -d= -f2)
  if [ -z "$APP_KEY" ] || [ "$APP_KEY" = "" ]; then
    echo "Generating application key..."
    (cd "$WORKSPACE" && php artisan key:generate --force) || true
  fi
fi

# Step 8: Wait for MySQL
echo ""
echo "Waiting for MySQL ($${MYSQL_HOST:-localhost})..."
T=0
until mysqladmin ping -h"$${MYSQL_HOST:-localhost}" -u laravel -plaravel --silent 2>/dev/null; do
  T=$((T+1)); [ $T -ge 30 ] && echo "MySQL timeout" && break; sleep 3
done
echo "MySQL ready"

# Step 9: Run migrations
if [ -f "$WORKSPACE/artisan" ]; then
  echo "Running migrations..."
  (cd "$WORKSPACE" && php artisan migrate --force 2>&1 | tail -5) || true
fi

# Step 10: CLAUDE.md
CLAUDE_MD="$WORKSPACE/CLAUDE.md"
if [ ! -f "$CLAUDE_MD" ] && [ -f "$WORKSPACE/artisan" ]; then
  {
    echo "# Claude Code - Laravel Workspace"
    echo ""
    echo "## Project"
    echo "- Framework: Laravel"
    echo "- PHP: $(php -r 'echo PHP_VERSION;')"
    echo "- Dir: $WORKSPACE"
    echo ""
    echo "## Services"
    echo "- MySQL: $${MYSQL_HOST} (user: laravel, pass: laravel, db: laravel)"
    echo "- Redis: $${REDIS_HOST}"
    echo ""
    echo "## Commands"
    echo '```'
    echo "php artisan serve --host=0.0.0.0 --port=8000"
    echo "php artisan migrate"
    echo "php artisan tinker"
    echo "php artisan test"
    echo "composer require <package>"
    echo "npm run dev"
    echo '```'
  } > "$CLAUDE_MD"
  echo "CLAUDE.md generated"
fi

# Step 11: Start Laravel dev server
if [ -f "$WORKSPACE/artisan" ]; then
  echo "Starting Laravel dev server on port 8000..."
  (cd "$WORKSPACE" && php artisan serve --host=0.0.0.0 --port=8000 >/tmp/laravel-serve.log 2>&1) &
fi

# Step 12: Start VS Code — bind to 127.0.0.1 (agent-local, IPv4 only)
echo "Starting VS Code..."
code-server \
  --bind-addr 127.0.0.1:8081 \
  --auth none \
  --disable-telemetry \
  "$WORKSPACE" >/tmp/code-server.log 2>&1 &

# Step 13: Start phpMyAdmin — bind to 127.0.0.1
echo "Starting phpMyAdmin..."
sudo tee /opt/phpmyadmin/config.inc.php >/dev/null <<PMAEOF
<?php
\$cfg['Servers'][1]['host']      = getenv('MYSQL_HOST') ?: 'localhost';
\$cfg['Servers'][1]['user']      = 'laravel';
\$cfg['Servers'][1]['password']  = 'laravel';
\$cfg['Servers'][1]['auth_type'] = 'config';
\$cfg['blowfish_secret']         = '$${BLOWFISH_SECRET:-coder-dev-fallback-secret}';
PMAEOF
php -S 127.0.0.1:8082 -t /opt/phpmyadmin/ >/tmp/phpmyadmin.log 2>&1 &

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DONE — use app buttons in Coder dashboard"
echo "  Laravel App: http://localhost:8000"
echo "  VS Code:     http://localhost:8081"
echo "  phpMyAdmin:  http://localhost:8082"
echo "  Claude:      claude"
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
    display_name = "Laravel Version"
    key          = "laravel_version"
    script       = "cd /home/coder/workspace && php artisan --version 2>/dev/null || echo 'not installed'"
    interval     = 60
    timeout      = 10
  }
}

# ── Apps ──────────────────────────────────────────────────────────────────────

resource "coder_app" "laravel" {
  agent_id     = coder_agent.main.id
  slug         = "laravel"
  display_name = "Laravel App"
  url          = "http://127.0.0.1:8000"
  icon         = "/icon/php.svg"
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
