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

variable "flutter_channel" {
  type        = string
  default     = "stable"
  description = "Flutter channel (stable, beta, dev)"
}

variable "java_version" {
  type        = string
  default     = "17"
  description = "JDK version (17, 21)"
}

variable "project_base_path" {
  type        = string
  default     = "/home/ubuntu/laravel-flutter-projects"
  description = "Host path where projects are stored"
}

# ── Parameters (user-facing at workspace creation) ───────────────────────────

data "coder_parameter" "laravel_repo_url" {
  name         = "laravel_repo_url"
  display_name = "Laravel Repo URL"
  description  = "HTTPS URL of the Laravel backend repository"
  default      = ""
  mutable      = true
}

data "coder_parameter" "laravel_repo_branch" {
  name         = "laravel_repo_branch"
  display_name = "Laravel Branch"
  description  = "Branch to clone for the Laravel project"
  default      = "main"
  mutable      = true
}

data "coder_parameter" "flutter_repo_url" {
  name         = "flutter_repo_url"
  display_name = "Flutter Repo URL"
  description  = "HTTPS URL of the Flutter app repository"
  default      = ""
  mutable      = true
}

data "coder_parameter" "flutter_repo_branch" {
  name         = "flutter_repo_branch"
  display_name = "Flutter Branch"
  description  = "Branch to clone for the Flutter project"
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

resource "docker_network" "app_network" {
  name     = "coder-${data.coder_workspace.me.id}-lf"
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
    name    = docker_network.app_network.name
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
    name    = docker_network.app_network.name
    aliases = ["redis"]
  }

  volumes {
    volume_name    = docker_volume.redis_data.name
    container_path = "/data"
  }
}

# ── Dev image ────────────────────────────────────────────────────────────────

resource "docker_image" "dev" {
  name = "lf-dev-${data.coder_workspace.me.id}"
  build {
    context    = path.module
    dockerfile = "Dockerfile.dev"
    build_args = {
      PHP_VERSION     = var.php_version
      FLUTTER_CHANNEL = var.flutter_channel
      JAVA_VERSION    = var.java_version
    }
  }
  triggers = {
    dockerfile      = filemd5("${path.module}/Dockerfile.dev")
    php_version     = var.php_version
    flutter_channel = var.flutter_channel
    java_version    = var.java_version
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
    name = docker_network.app_network.name
  }

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    "MYSQL_HOST=mysql",
    "REDIS_HOST=redis",
    "GIT_TOKEN=${var.git_token}",
    "LARAVEL_REPO_URL=${data.coder_parameter.laravel_repo_url.value}",
    "LARAVEL_REPO_BRANCH=${data.coder_parameter.laravel_repo_branch.value}",
    "FLUTTER_REPO_URL=${data.coder_parameter.flutter_repo_url.value}",
    "FLUTTER_REPO_BRANCH=${data.coder_parameter.flutter_repo_branch.value}",
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

  volumes {
    host_path      = var.project_base_path
    container_path = "/home/coder/workspace"
  }

  entrypoint = ["sh", "-c", replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]

  depends_on = [docker_container.mysql]
}

# ── Coder agent ───────────────────────────────────────────────────────────────

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"
  dir  = "/home/coder/workspace"

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
    LARAVEL_DIR="$WORKSPACE/backend"
    FLUTTER_DIR="$WORKSPACE/mobile"

    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~ 2>/dev/null || true
      touch ~/.init_done
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Laravel + Flutter Full-Stack Workspace"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    sudo chown -R coder:coder "$WORKSPACE" 2>/dev/null || true
    sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

    # Git credentials
    if [ -n "$${GIT_TOKEN:-}" ]; then
      git config --global credential.helper store
      for URL in "$${LARAVEL_REPO_URL:-}" "$${FLUTTER_REPO_URL:-}"; do
        if [ -n "$URL" ]; then
          HOST=$(echo "$URL" | sed -E 's|https://([^/]+)/.*|\1|')
          grep -q "$HOST" ~/.git-credentials 2>/dev/null || \
            echo "https://oauth2:$${GIT_TOKEN}@$${HOST}" >> ~/.git-credentials
        fi
      done
      chmod 600 ~/.git-credentials 2>/dev/null || true
    fi

    # ── Laravel Backend ────────────────────────────────────────────────────────
    LARAVEL_REPO_URL="$${LARAVEL_REPO_URL:-}"
    LARAVEL_REPO_BRANCH="$${LARAVEL_REPO_BRANCH:-main}"

    if [ -n "$LARAVEL_REPO_URL" ]; then
      mkdir -p "$LARAVEL_DIR"
      if [ ! -d "$LARAVEL_DIR/.git" ]; then
        echo "Cloning Laravel repo..."
        TMPDIR=$(mktemp -d)
        git clone --branch "$LARAVEL_REPO_BRANCH" --single-branch "$LARAVEL_REPO_URL" "$TMPDIR" 2>&1 | tail -5 || {
          echo "FAILED to clone"; rm -rf "$TMPDIR"
        }
        if [ -d "$TMPDIR/.git" ]; then
          shopt -s dotglob; mv "$TMPDIR"/* "$LARAVEL_DIR/" 2>/dev/null || true; shopt -u dotglob
          rm -rf "$TMPDIR"
        fi
      else
        git -C "$LARAVEL_DIR" pull --ff-only 2>&1 | tail -3 || true
      fi

      [ -f "$LARAVEL_DIR/composer.json" ] && (cd "$LARAVEL_DIR" && composer install --no-interaction --prefer-dist -q 2>&1 | tail -5) || true
      [ -f "$LARAVEL_DIR/package.json" ] && (cd "$LARAVEL_DIR" && npm install --silent 2>&1 | tail -5) || true

      if [ -f "$LARAVEL_DIR/.env.example" ] && [ ! -f "$LARAVEL_DIR/.env" ]; then
        cp "$LARAVEL_DIR/.env.example" "$LARAVEL_DIR/.env"
        sed -i "s|^DB_HOST=.*|DB_HOST=mysql|"            "$LARAVEL_DIR/.env"
        sed -i "s|^DB_DATABASE=.*|DB_DATABASE=laravel|"   "$LARAVEL_DIR/.env"
        sed -i "s|^DB_USERNAME=.*|DB_USERNAME=laravel|"   "$LARAVEL_DIR/.env"
        sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=laravel|"   "$LARAVEL_DIR/.env"
        sed -i "s|^REDIS_HOST=.*|REDIS_HOST=redis|"       "$LARAVEL_DIR/.env"
      fi

      if [ -f "$LARAVEL_DIR/artisan" ]; then
        APP_KEY=$(grep "^APP_KEY=" "$LARAVEL_DIR/.env" 2>/dev/null | cut -d= -f2)
        [ -z "$APP_KEY" ] && (cd "$LARAVEL_DIR" && php artisan key:generate --force) || true
      fi
    fi

    # Wait for MySQL
    echo "Waiting for MySQL..."
    T=0
    until mysqladmin ping -h mysql -u laravel -plaravel --silent 2>/dev/null; do
      T=$((T+1)); [ $T -ge 30 ] && echo "MySQL timeout" && break; sleep 3
    done

    [ -f "$LARAVEL_DIR/artisan" ] && (cd "$LARAVEL_DIR" && php artisan migrate --force 2>&1 | tail -5) || true

    # ── Flutter Mobile ─────────────────────────────────────────────────────────
    FLUTTER_REPO_URL="$${FLUTTER_REPO_URL:-}"
    FLUTTER_REPO_BRANCH="$${FLUTTER_REPO_BRANCH:-main}"

    if [ -n "$FLUTTER_REPO_URL" ]; then
      mkdir -p "$FLUTTER_DIR"
      if [ ! -d "$FLUTTER_DIR/.git" ]; then
        echo "Cloning Flutter repo..."
        TMPDIR=$(mktemp -d)
        git clone --branch "$FLUTTER_REPO_BRANCH" --single-branch "$FLUTTER_REPO_URL" "$TMPDIR" 2>&1 | tail -5 || {
          echo "FAILED to clone"; rm -rf "$TMPDIR"
        }
        if [ -d "$TMPDIR/.git" ]; then
          shopt -s dotglob; mv "$TMPDIR"/* "$FLUTTER_DIR/" 2>/dev/null || true; shopt -u dotglob
          rm -rf "$TMPDIR"
        fi
      else
        git -C "$FLUTTER_DIR" pull --ff-only 2>&1 | tail -3 || true
      fi

      [ -f "$FLUTTER_DIR/pubspec.yaml" ] && (cd "$FLUTTER_DIR" && flutter pub get 2>&1 | tail -5) || true
    fi

    flutter doctor 2>&1 || true

    # Start Laravel dev server
    [ -f "$LARAVEL_DIR/artisan" ] && (cd "$LARAVEL_DIR" && php artisan serve --host=0.0.0.0 --port=8000 >/tmp/laravel-serve.log 2>&1) &

    # phpMyAdmin
    sudo tee /opt/phpmyadmin/config.inc.php >/dev/null <<PMAEOF
<?php
\$cfg['Servers'][1]['host']      = 'mysql';
\$cfg['Servers'][1]['user']      = 'laravel';
\$cfg['Servers'][1]['password']  = 'laravel';
\$cfg['Servers'][1]['auth_type'] = 'config';
\$cfg['blowfish_secret']         = '$${BLOWFISH_SECRET:-fallback}';
PMAEOF
    php -S 127.0.0.1:8082 -t /opt/phpmyadmin/ >/tmp/phpmyadmin.log 2>&1 &

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Laravel API: http://localhost:8000"
    echo "  phpMyAdmin:  http://localhost:8082"
    echo "  Claude:      claude"
    echo "  backend/ — Laravel    mobile/ — Flutter"
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
    display_name = "Flutter Version"
    key          = "flutter_version"
    script       = "flutter --version | head -1"
    interval     = 60
    timeout      = 10
  }
}

# ── Apps ──────────────────────────────────────────────────────────────────────

resource "coder_app" "laravel" {
  agent_id     = coder_agent.main.id
  slug         = "laravel"
  display_name = "Laravel API"
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
