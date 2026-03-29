terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

# ── Variables ──────────────────────────────────────────────────────────────────

variable "docker_socket" {
  default     = ""
  description = "(Optional) Docker socket URI"
  type        = string
}

variable "git_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Git personal access token for cloning private repos"
}

variable "php_version" {
  type        = string
  default     = "8.2"
  description = "PHP version (8.1, 8.2, 8.3)"
}

variable "project_base_path" {
  type        = string
  default     = "/home/ubuntu/laravel-projects"
  description = "Host path where the Laravel project is stored"
}

# ── Parameters (user-facing at workspace creation) ───────────────────────────

data "coder_parameter" "node_version" {
  name         = "node_version"
  display_name = "Node.js Version"
  description  = "Node.js major version for the dev container"
  type         = "string"
  form_type    = "dropdown"
  default      = "22"
  mutable      = true

  option {
    name  = "18"
    value = "18"
  }
  option {
    name  = "20"
    value = "20"
  }
  option {
    name  = "22"
    value = "22"
  }
}

data "coder_parameter" "php_version" {
  name         = "php_version"
  display_name = "PHP Version"
  description  = "PHP version for the dev container"
  type         = "string"
  form_type    = "dropdown"
  default      = "8.2"
  mutable      = true

  option {
    name  = "8.1"
    value = "8.1"
  }
  option {
    name  = "8.2"
    value = "8.2"
  }
  option {
    name  = "8.3"
    value = "8.3"
  }
  option {
    name  = "8.4"
    value = "8.4"
  }
  option {
    name  = "8.5"
    value = "8.5"
  }
}

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

# ── Locals & Data Sources ────────────────────────────────────────────────────

locals {
  username       = data.coder_workspace_owner.me.name
  workspace_name = data.coder_workspace.me.name
}

provider "docker" {
  host = var.docker_socket != "" ? var.docker_socket : null
}

data "coder_provisioner"     "me" {}
data "coder_workspace"       "me" {}
data "coder_workspace_owner" "me" {}

# ── Random secret for phpMyAdmin ─────────────────────────────────────────────

resource "random_string" "blowfish_secret" {
  length  = 32
  special = false
}

# ── Docker network ────────────────────────────────────────────────────────────

resource "docker_network" "laravel_network" {
  name     = "coder-${data.coder_workspace.me.id}-laravel"
  ipv6     = false
  internal = false
}

# ── Volumes ──────────────────────────────────────────────────────────────────

resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.id}-home"
  lifecycle { ignore_changes = all }
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
  name    = "coder-${local.username}-${lower(local.workspace_name)}-mysql"
  restart = "unless-stopped"

  networks_advanced {
    name    = docker_network.laravel_network.name
    aliases = ["mysql"]
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

  healthcheck {
    test         = ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-plaravel"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 5
    start_period = "30s"
  }
}

# ── Redis ─────────────────────────────────────────────────────────────────────

resource "docker_container" "redis" {
  count   = data.coder_workspace.me.start_count
  image   = "redis:7-alpine"
  name    = "coder-${local.username}-${lower(local.workspace_name)}-redis"
  restart = "unless-stopped"

  networks_advanced {
    name    = docker_network.laravel_network.name
    aliases = ["redis"]
  }

  volumes {
    volume_name    = docker_volume.redis_data.name
    container_path = "/data"
  }
}

# ── Dev image ────────────────────────────────────────────────────────────────

resource "docker_image" "dev" {
  name = "laravel-dev-${data.coder_workspace.me.id}"
  build {
    context    = path.module
    dockerfile = "Dockerfile.dev"
    build_args = {
      PHP_VERSION = data.coder_parameter.php_version.value
      NODE_MAJOR  = data.coder_parameter.node_version.value
    }
  }
  triggers = {
    dockerfile   = filemd5("${path.module}/Dockerfile.dev")
    php_version  = data.coder_parameter.php_version.value
    node_version = data.coder_parameter.node_version.value
  }
}

# ── Dev container ─────────────────────────────────────────────────────────────

resource "docker_container" "dev" {
  count    = data.coder_workspace.me.start_count
  image    = docker_image.dev.image_id
  name     = "coder-${local.username}-${lower(local.workspace_name)}"
  hostname = data.coder_workspace.me.name
  restart  = "unless-stopped"

  networks_advanced {
    name = docker_network.laravel_network.name
  }

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    "MYSQL_HOST=mysql",
    "REDIS_HOST=redis",
    "GIT_TOKEN=${var.git_token}",
    "REPO_URL=${data.coder_parameter.repo_url.value}",
    "REPO_BRANCH=${data.coder_parameter.repo_branch.value}",
    "BLOWFISH_SECRET=${random_string.blowfish_secret.result}",
  ]

  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }

  volumes {
    volume_name    = docker_volume.home_volume.name
    container_path = "/home/coder"
    read_only      = false
  }

  entrypoint = ["sh", "-c", replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]

  depends_on = [docker_container.mysql]
}

# ── Coder agent ───────────────────────────────────────────────────────────────

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
  }

  startup_script = <<-EOT
    # NO set -e — script must survive errors or agent disconnects
    set -uo pipefail

    WORKSPACE="/home/coder/workspace"
    mkdir -p "$WORKSPACE"

    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~ 2>/dev/null || true
      touch ~/.init_done
    fi

    # Install nvm for the coder user
    touch ~/.bashrc
    if [ ! -d "/home/coder/.nvm" ]; then
      curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    fi
    if ! grep -q 'NVM_DIR' ~/.bashrc 2>/dev/null; then
      echo 'export NVM_DIR="$HOME/.nvm"' >> ~/.bashrc
      echo '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' >> ~/.bashrc
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Laravel Dev Workspace"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    sudo chown -R coder:coder /home/coder 2>/dev/null || true
    sudo chmod -R 775 /home/coder/workspace 2>/dev/null || true
    sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

    if [ -n "$${GIT_TOKEN:-}" ] && [ -n "$${REPO_URL:-}" ]; then
      git config --global credential.helper store
      REPO_HOST=$(echo "$REPO_URL" | sed -E 's|https://([^/]+)/.*|\1|')
      echo "https://oauth2:$${GIT_TOKEN}@$${REPO_HOST}" >> ~/.git-credentials
      chmod 600 ~/.git-credentials 2>/dev/null || true
    fi

    # Clone repo if not exists
    if [ -n "$${REPO_URL:-}" ] && [ ! -d "$WORKSPACE/.git" ]; then
      echo "Cloning $${REPO_URL} (branch: $${REPO_BRANCH:-main})..."
      TMPDIR=$(mktemp -d)
      git clone --branch "$${REPO_BRANCH:-main}" --single-branch "$REPO_URL" "$TMPDIR" 2>&1 | tail -5 || {
        echo "FAILED to clone"; rm -rf "$TMPDIR"
      }
      if [ -d "$TMPDIR/.git" ]; then
        shopt -s dotglob; mv "$TMPDIR"/* "$WORKSPACE/" 2>/dev/null || true; shopt -u dotglob
        rm -rf "$TMPDIR"
      fi
    elif [ -d "$WORKSPACE/.git" ]; then
      git -C "$WORKSPACE" pull --ff-only 2>&1 | tail -3 || true
    fi

    # Composer & npm install
    [ -f "$WORKSPACE/composer.json" ] && (cd "$WORKSPACE" && composer install --no-interaction --prefer-dist -q 2>&1 | tail -5) || true
    [ -f "$WORKSPACE/package.json" ] && (cd "$WORKSPACE" && npm install --silent 2>&1 | tail -5) || true

    # Laravel .env setup — stored outside sync root so local .env is independent
    ENV_REMOTE="/tmp/laravel-remote.env"
    if [ -f "$WORKSPACE/.env.example" ] && [ ! -f "$ENV_REMOTE" ]; then
      cp "$WORKSPACE/.env.example" "$ENV_REMOTE"
      sed -i "s|^DB_HOST=.*|DB_HOST=mysql|"            "$ENV_REMOTE"
      sed -i "s|^DB_DATABASE=.*|DB_DATABASE=laravel|"   "$ENV_REMOTE"
      sed -i "s|^DB_USERNAME=.*|DB_USERNAME=laravel|"   "$ENV_REMOTE"
      sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=laravel|"   "$ENV_REMOTE"
      sed -i "s|^REDIS_HOST=.*|REDIS_HOST=redis|"       "$ENV_REMOTE"
      if ! grep -q "^ASSET_URL=" "$ENV_REMOTE"; then
        echo "ASSET_URL=/" >> "$ENV_REMOTE"
      fi
    fi

    # Always ensure trusted proxies and HTTPS are set for Coder's reverse proxy
    if [ -f "$ENV_REMOTE" ]; then
      grep -q "^TRUSTED_PROXIES=" "$ENV_REMOTE" && \
        sed -i "s|^TRUSTED_PROXIES=.*|TRUSTED_PROXIES=*|" "$ENV_REMOTE" || \
        echo "TRUSTED_PROXIES=*" >> "$ENV_REMOTE"
      grep -q "^FORCE_HTTPS=" "$ENV_REMOTE" && \
        sed -i "s|^FORCE_HTTPS=.*|FORCE_HTTPS=true|" "$ENV_REMOTE" || \
        echo "FORCE_HTTPS=true" >> "$ENV_REMOTE"
    fi

    # Symlink .env → remote env (Coder Desktop won't sync symlink targets outside root)
    if [ -f "$ENV_REMOTE" ]; then
      ln -sf "$ENV_REMOTE" "$WORKSPACE/.env"
    fi

    # Generate app key
    if [ -f "$WORKSPACE/artisan" ]; then
      APP_KEY=$(grep "^APP_KEY=" "$WORKSPACE/.env" 2>/dev/null | cut -d= -f2)
      [ -z "$APP_KEY" ] && (cd "$WORKSPACE" && php artisan key:generate --force) || true
    fi

    # Wait for MySQL
    echo "Waiting for MySQL..."
    T=0
    until mysqladmin ping -h mysql -u laravel -plaravel --silent 2>/dev/null; do
      T=$((T+1)); [ $T -ge 30 ] && echo "MySQL timeout" && break; sleep 3
    done

    # Migrations
    [ -f "$WORKSPACE/artisan" ] && (cd "$WORKSPACE" && php artisan migrate --force 2>&1 | tail -5) || true

    # Start Laravel dev server
    if [ -f "$WORKSPACE/artisan" ]; then
      cd "$WORKSPACE"
      nohup php artisan serve --host=0.0.0.0 --port=8000 </dev/null >/tmp/laravel-serve.log 2>&1 &
      cd -
    fi

    # phpMyAdmin
    sudo tee /opt/phpmyadmin/config.inc.php >/dev/null <<PMAEOF
<?php
\$cfg['Servers'][1]['host']      = 'mysql';
\$cfg['Servers'][1]['user']      = 'laravel';
\$cfg['Servers'][1]['password']  = 'laravel';
\$cfg['Servers'][1]['auth_type'] = 'config';
\$cfg['blowfish_secret']         = '$${BLOWFISH_SECRET:-fallback}';
PMAEOF
    nohup php -S 0.0.0.0:8082 -t /opt/phpmyadmin/ </dev/null >/tmp/phpmyadmin.log 2>&1 &

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Laravel: http://localhost:8000"
    echo "  phpMyAdmin: http://localhost:8082"
    echo "  Claude: claude"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  EOT

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "PHP Version"
    key          = "php_version"
    script       = "php --version | head -1"
    interval     = 60
    timeout      = 5
  }

  metadata {
    display_name = "Node.js Version"
    key          = "node_version"
    script       = "node --version"
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

  healthcheck {
    url       = "http://127.0.0.1:8000"
    interval  = 15
    threshold = 6
  }
}

resource "coder_app" "phpmyadmin" {
  agent_id     = coder_agent.main.id
  slug         = "phpmyadmin"
  display_name = "phpMyAdmin"
  url          = "http://127.0.0.1:8082"
  icon         = "https://www.phpmyadmin.net/static/favicon.ico"
  share        = "owner"
  subdomain    = true

  healthcheck {
    url       = "http://127.0.0.1:8082"
    interval  = 15
    threshold = 6
  }
}

# ── Code-server (VS Code in browser) ─────────────────────────────────────────

module "code-server" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/code-server/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main.id
  order    = 1
}

# ── Claude Code ──────────────────────────────────────────────────────────────

module "claude-code" {
  count               = data.coder_workspace.me.start_count
  source              = "registry.coder.com/coder/claude-code/coder"
  version             = "~> 1.0"
  agent_id            = coder_agent.main.id
  install_claude_code = false
  order               = 99
}

# ── Claude Code UI (web interface) ───────────────────────────────────────────

resource "coder_script" "claude_code_ui_install" {
  agent_id     = coder_agent.main.id
  display_name = "Claude Code UI"
  icon         = "/emojis/1f4ac.png"
  run_on_start = true
  start_blocks_login = false
  script = <<-EOT
    #!/usr/bin/env bash

    PORT=13376
    CODER_HOME="/home/coder"
    LOG="$${CODER_HOME}/.claude-code-ui.log"

    echo "Starting Claude Code UI on port $${PORT}..."
    echo " UI user    : coder"
    echo " UI pass    : coder"

    export SERVER_PORT="$${PORT}"
    export DATABASE_PATH="$${CODER_HOME}/.claude-code-ui.db"

    # Remove old DB with incompatible schema (let app recreate it)
    if [ -f "$${DATABASE_PATH}" ]; then
      if ! sqlite3 "$${DATABASE_PATH}" "SELECT api_key FROM api_keys LIMIT 0;" 2>/dev/null; then
        echo "Removing incompatible Claude Code UI database..."
        rm -f "$${DATABASE_PATH}"
      fi
    fi

    nohup npx -y @siteboon/claude-code-ui </dev/null > "$${LOG}" 2>&1 &
    CCUI_PID=$!
    echo $${CCUI_PID} > "$${CODER_HOME}/.claude-code-ui.pid"

    # Wait for server to be ready
    for i in $(seq 1 30); do
      if curl -s http://localhost:$${PORT} > /dev/null 2>&1; then
        echo "Claude Code UI is running on port $${PORT}"

        # Create default user on first run via registration API
        REGISTER=$(curl -s -o /dev/null -w "%%{http_code}" \
          -X POST http://localhost:$${PORT}/api/auth/register \
          -H "Content-Type: application/json" \
          -d '{"username":"coder","password":"coder"}')
        if [ "$${REGISTER}" = "201" ]; then
          echo "Default user 'coder' created"
        fi
        exit 0
      fi
      if ! kill -0 $${CCUI_PID} 2>/dev/null; then
        echo "ERROR: Claude Code UI crashed. Log:"
        tail -20 "$${LOG}" 2>/dev/null || true
        exit 1
      fi
      sleep 2
    done
    echo "WARNING: Claude Code UI did not respond within 60s. Check $${LOG}"
  EOT
}

resource "coder_app" "claude_code_ui" {
  agent_id     = coder_agent.main.id
  slug         = "ccui"
  display_name = "Claude Code UI"
  icon         = "/emojis/1f4ac.png"
  url          = "http://localhost:13376"
  share        = "owner"
  subdomain    = true
  open_in      = "tab"
}
