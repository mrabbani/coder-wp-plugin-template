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
  description = "Git PAT set at template level (fallback if user doesn't provide one)"
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

data "coder_parameter" "git_token" {
  name         = "git_token"
  display_name = "Git Token"
  description  = "Personal access token for cloning private repos (optional)"
  default      = ""
  mutable      = true
  type         = "string"
}

# ── Locals & Data Sources ────────────────────────────────────────────────────

locals {
  username       = data.coder_workspace_owner.me.name
  workspace_name = data.coder_workspace.me.name
  git_token      = data.coder_parameter.git_token.value != "" ? data.coder_parameter.git_token.value : var.git_token
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

resource "docker_volume" "workspace_volume" {
  name = "coder-${data.coder_workspace.me.id}-workspace"
  lifecycle { ignore_changes = all }
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
      PHP_VERSION     = data.coder_parameter.php_version.value
      FLUTTER_CHANNEL = var.flutter_channel
      JAVA_VERSION    = var.java_version
    }
  }
  triggers = {
    dockerfile      = filemd5("${path.module}/Dockerfile.dev")
    php_version     = data.coder_parameter.php_version.value
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
    "GIT_TOKEN=${local.git_token}",
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
    volume_name    = docker_volume.workspace_volume.name
    container_path = "/home/coder/workspace"
    read_only      = false
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
    echo "  Laravel + Flutter Full-Stack Workspace"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    sudo chown -R coder:coder /home/coder 2>/dev/null || true
    sudo chmod -R 775 /home/coder/workspace 2>/dev/null || true
    sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

    # Git credentials — token works for both GitHub and GitLab
    if [ -n "$${GIT_TOKEN:-}" ]; then
      git config --global credential.helper store
      echo "https://oauth2:$${GIT_TOKEN}@github.com" >> ~/.git-credentials
      echo "https://oauth2:$${GIT_TOKEN}@gitlab.com" >> ~/.git-credentials
      chmod 600 ~/.git-credentials 2>/dev/null || true
      echo "Git credentials configured"
    fi

    # Wait for MySQL
    echo "Waiting for MySQL..."
    T=0
    until mysqladmin ping -h mysql -u laravel -plaravel --silent 2>/dev/null; do
      T=$((T+1)); [ $T -ge 30 ] && echo "MySQL timeout" && break; sleep 3
    done
    echo "MySQL ready"

    # ── Laravel auto-setup (runs if artisan exists in any subdir) ──────────
    for DIR in "$WORKSPACE"/*/; do
      if [ -f "$DIR/artisan" ]; then
        echo "Found Laravel project at $DIR"

        # .env setup
        if [ -f "$DIR/.env.example" ] && [ ! -f "$DIR/.env" ]; then
          cp "$DIR/.env.example" "$DIR/.env"
          sed -i "s|^DB_HOST=.*|DB_HOST=mysql|"            "$DIR/.env"
          sed -i "s|^DB_DATABASE=.*|DB_DATABASE=laravel|"   "$DIR/.env"
          sed -i "s|^DB_USERNAME=.*|DB_USERNAME=laravel|"   "$DIR/.env"
          sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=laravel|"   "$DIR/.env"
          sed -i "s|^REDIS_HOST=.*|REDIS_HOST=redis|"       "$DIR/.env"
          if ! grep -q "^ASSET_URL=" "$DIR/.env"; then
            echo "ASSET_URL=/" >> "$DIR/.env"
          fi
          echo ".env configured for $DIR"
        fi

        # Force HTTPS when served behind Coder's reverse proxy
        if [ -f "$DIR/.env" ]; then
          grep -q "^TRUSTED_PROXIES=" "$DIR/.env" && \
            sed -i "s|^TRUSTED_PROXIES=.*|TRUSTED_PROXIES=*|" "$DIR/.env" || \
            echo "TRUSTED_PROXIES=*" >> "$DIR/.env"
          grep -q "^FORCE_HTTPS=" "$DIR/.env" && \
            sed -i "s|^FORCE_HTTPS=.*|FORCE_HTTPS=true|" "$DIR/.env" || \
            echo "FORCE_HTTPS=true" >> "$DIR/.env"
        fi

        # App key
        APP_KEY=$(grep "^APP_KEY=" "$DIR/.env" 2>/dev/null | cut -d= -f2)
        [ -z "$APP_KEY" ] && (cd "$DIR" && php artisan key:generate --force) || true

        # Composer & npm
        [ -f "$DIR/composer.json" ] && (cd "$DIR" && composer install --no-interaction --prefer-dist -q 2>&1 | tail -5) || true
        [ -f "$DIR/package.json" ] && (cd "$DIR" && npm install --silent 2>&1 | tail -5) || true

        # Migrations
        (cd "$DIR" && php artisan migrate --force 2>&1 | tail -5) || true

        # Serve
        echo "Starting Laravel dev server from $DIR on port 8000..."
        cd "$DIR"
        nohup php artisan serve --host=0.0.0.0 --port=8000 </dev/null >/tmp/laravel-serve.log 2>&1 &
        cd -
        break
      fi
    done

    # ── Flutter auto-setup (runs if pubspec.yaml exists in any subdir) ─────
    for DIR in "$WORKSPACE"/*/; do
      if [ -f "$DIR/pubspec.yaml" ]; then
        echo "Found Flutter project at $DIR"
        (cd "$DIR" && flutter pub get 2>&1 | tail -5) || true
        break
      fi
    done

    flutter doctor >/tmp/flutter-doctor.log 2>&1 || true

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
    echo "  Laravel API: http://localhost:8000 (if project found)"
    echo "  phpMyAdmin:  http://localhost:8082"
    echo "  Claude:      claude"
    echo ""
    echo "  Clone your repos into workspace/ then restart"
    echo "  workspace to auto-setup Laravel & Flutter"
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
