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

variable "mysql_root_password" {
  default     = ""
  description = "MySQL root password (leave blank to auto-generate)"
  type        = string
  sensitive   = true
}

variable "wordpress_db_name" {
  default     = "wordpress"
  description = "WordPress database name"
  type        = string
}

variable "wordpress_db_user" {
  default     = "wpuser"
  description = "WordPress database user"
  type        = string
}

variable "wordpress_db_password" {
  default     = ""
  description = "WordPress database password (leave blank to auto-generate)"
  type        = string
  sensitive   = true
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

# ── Locals & Data Sources ──────────────────────────────────────────────────────

locals {
  username           = data.coder_workspace_owner.me.name
  workspace_name     = data.coder_workspace.me.name
  mysql_root_pass    = var.mysql_root_password != "" ? var.mysql_root_password : random_password.mysql_root[0].result
  wp_db_pass         = var.wordpress_db_password != "" ? var.wordpress_db_password : random_password.wp_db[0].result

  # Shared label set applied to every Docker resource for easy cleanup
  coder_labels = {
    "coder.owner"      = data.coder_workspace_owner.me.name
    "coder.owner_id"   = data.coder_workspace_owner.me.id
    "coder.workspace_id"   = data.coder_workspace.me.id
    "coder.workspace_name" = data.coder_workspace.me.name
  }
}

provider "docker" {
  host = var.docker_socket != "" ? var.docker_socket : null
}

data "coder_provisioner"    "me" {}
data "coder_workspace"      "me" {}
data "coder_workspace_owner" "me" {}

# ── Random Passwords (generated when not supplied) ─────────────────────────────

resource "random_password" "mysql_root" {
  count   = var.mysql_root_password == "" ? 1 : 0
  length  = 20
  special = false
}

resource "random_password" "wp_db" {
  count   = var.wordpress_db_password == "" ? 1 : 0
  length  = 20
  special = false
}

# ── Coder Agent ────────────────────────────────────────────────────────────────

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  startup_script = <<-EOT
    # NO set -e — script must survive errors or agent disconnects

    # Fix git credential issues with Coder agent — persist into all shells
    git config --global credential.helper 'cache --timeout=360000'
    for rc in /home/coder/.bashrc /home/coder/.zshrc; do
      if ! grep -q 'unset GIT_ASKPASS' "$rc" 2>/dev/null; then
        cat >> "$rc" <<'RCEOF'

# Prevent Coder agent from hijacking git credentials
unset GIT_ASKPASS
unset SSH_ASKPASS
unset CODER_AGENT_TOKEN
RCEOF
      fi
    done

    # First-run skeleton copy
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

    # Install socat for IPv4 proxying
    if ! command -v socat &>/dev/null; then
      sudo apt-get update -qq && sudo apt-get install -y socat -qq 2>/dev/null || true
    fi

    # Start IPv4 proxies (Docker DNS returns IPv6 but containers listen on IPv4)
    for entry in "wordpress:80:8080" "phpmyadmin:80:8081"; do
      CONTAINER=$(echo "$entry" | cut -d: -f1)
      CPORT=$(echo "$entry" | cut -d: -f2)
      LPORT=$(echo "$entry" | cut -d: -f3)
      for attempt in $(seq 1 30); do
        IPV4=$(getent ahostsv4 "$CONTAINER" 2>/dev/null | awk 'NR==1{print $1}' || true)
        if [ -n "$IPV4" ]; then
          echo "Proxy: 127.0.0.1:$LPORT -> $IPV4:$CPORT ($CONTAINER)"
          socat TCP-LISTEN:$LPORT,bind=127.0.0.1,fork,reuseaddr TCP4:$IPV4:$CPORT >/dev/null 2>&1 &
          break
        fi
        sleep 2
      done
    done

    # Make WordPress files writable by coder user
    # Wait for WordPress container to finish populating files
    for i in $(seq 1 30); do
      [ -f /home/coder/wordpress/wp-config.php ] && break
      sleep 2
    done
    sudo chown -R coder:coder /home/coder/wordpress 2>/dev/null || true
    sudo chmod -R 777 /home/coder/wordpress 2>/dev/null || true


    # Print connection info to the workspace log
    echo "============================================"
    echo " WordPress  → via Coder dashboard"
    echo " phpMyAdmin → via Coder dashboard"
    echo " DB name    : ${var.wordpress_db_name}"
    echo " DB user    : ${var.wordpress_db_user}"
    echo " DB pass    : ${local.wp_db_pass}"
    echo " MySQL root : ${local.mysql_root_pass}"
    echo "============================================"
  EOT

  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email

    # Expose DB credentials as env vars inside the agent container
    MYSQL_ROOT_PASSWORD = local.mysql_root_pass
    WP_DB_NAME          = var.wordpress_db_name
    WP_DB_USER          = var.wordpress_db_user
    WP_DB_PASSWORD      = local.wp_db_pass
  }

  # ── b ────────────────────────────────────────────────────

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
    key          = "2_php_version"
    script       = "php --version | head -1"
    interval     = 60
    timeout      = 5
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "WordPress Status"
    key          = "4_wp_status"
    script       = "curl -sf -o /dev/null -w 'HTTP %%{http_code}' http://127.0.0.1:8080 || echo 'unreachable'"
    interval     = 30
    timeout      = 5
  }

  metadata {
    display_name = "MySQL Status"
    key          = "5_mysql_status"
    script       = "mysqladmin -h mysql -u root -p$MYSQL_ROOT_PASSWORD ping 2>/dev/null || echo 'unreachable'"
    interval     = 30
    timeout      = 5
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "6_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "7_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }
}

# ── Coder Apps (proxied URLs shown in dashboard) ───────────────────────────────

resource "coder_app" "wordpress" {
  agent_id     = coder_agent.main.id
  slug         = "wordpress"
  display_name = "WordPress"
  url          = "http://127.0.0.1:8080"
  icon         = "https://upload.wikimedia.org/wikipedia/commons/thumb/9/98/WordPress_blue_logo.svg/1200px-WordPress_blue_logo.svg.png"
  subdomain    = true
  share        = "owner"

  healthcheck {
    url       = "http://127.0.0.1:8080"
    interval  = 15
    threshold = 6
  }
}

resource "coder_app" "phpmyadmin" {
  agent_id     = coder_agent.main.id
  slug         = "phpmyadmin"
  display_name = "phpMyAdmin"
  url          = "http://127.0.0.1:8081"
  icon         = "https://www.phpmyadmin.net/static/favicon.ico"
  subdomain    = true
  share        = "owner"

  healthcheck {
    url       = "http://127.0.0.1:8081"
    interval  = 15
    threshold = 6
  }
}

# ── Code-server (VS Code in browser) ──────────────────────────────────────────

module "code-server" {
  count   = data.coder_workspace.me.start_count
  source  = "registry.coder.com/coder/code-server/coder"
  version = "~> 1.0"

  agent_id = coder_agent.main.id
  order    = 1
}

# ── Claude Code ───────────────────────────────────────────────────────────────

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
  display_name = "Install Claude Code UI"
  icon         = "/emojis/1f4ac.png"
  run_on_start = true
  start_blocks_login = false
  script = <<-EOT
    #!/usr/bin/env bash

    CODER_HOME="/home/coder"
    INSTALL_PATH="$${CODER_HOME}/.claude-code-ui"
    PORT=13376
    INIT_DB="${file("${path.module}/init.db.txt")}"

    echo "Installing Claude Code UI..."

    if ! command -v node > /dev/null; then
      echo "Node.js is not installed!"; exit 1
    fi
    if ! command -v npm > /dev/null; then
      echo "npm is not installed!"; exit 1
    fi

    # Ensure home dir is owned by coder (fresh volume may be root-owned)
    chown -R coder:coder "$${CODER_HOME}" 2>/dev/null || true

    mkdir -p "$${INSTALL_PATH}"

    if [ -d "$${INSTALL_PATH}/claudecodeui" ]; then
      cd "$${INSTALL_PATH}/claudecodeui"
      git pull origin main || echo "Failed to pull latest changes, continuing with existing version"
    else
      cd "$${INSTALL_PATH}"
      git clone --depth 1 -b main https://github.com/siteboon/claudecodeui.git
      cd claudecodeui
    fi

    # Install ALL deps (including devDependencies needed for vite build)
    rm -rf node_modules package-lock.json 2>/dev/null || true
    echo "Installing Claude Code UI dependencies..."
    NODE_ENV=development npm install 2>&1

    if [ ! -f "$${CODER_HOME}/.claude-code-ui.db" ]; then
      echo "Creating DB file..."
      echo "$${INIT_DB}" | base64 -d > "$${CODER_HOME}/.claude-code-ui.db"
    fi

    echo "Claude Code UI installation completed!"

    export PATH="$${CODER_HOME}/.local/bin:$${PATH}"
    printf '%s\n' \
      "PORT=$${PORT}" \
      "VITE_PORT=5173" \
      "VITE_IS_PLATFORM=true" \
      "VITE_CONTEXT_WINDOW=160000" \
      "CONTEXT_WINDOW=160000" \
      "DATABASE_PATH=$${CODER_HOME}/.claude-code-ui.db" \
      > .env

    # Build frontend assets first, then start server in production mode
    echo "Building Claude Code UI frontend..."
    npm run build 2>&1 || { echo "ERROR: vite build failed"; cat "$${CODER_HOME}/.claude-code-ui.log" 2>/dev/null || true; }

    export DATABASE_PATH="$${CODER_HOME}/.claude-code-ui.db"
    export NODE_ENV=production
    cd "$${INSTALL_PATH}/claudecodeui"
    nohup node server/index.js </dev/null > "$${CODER_HOME}/.claude-code-ui.log" 2>&1 &
    CCUI_PID=$!
    echo $${CCUI_PID} > "$${CODER_HOME}/.claude-code-ui.pid"
    echo "Claude Code UI started with PID $${CCUI_PID} on port $${PORT}"

    # Wait for the server to be ready
    for i in $(seq 1 15); do
      if curl -s http://localhost:$${PORT} > /dev/null 2>&1; then
        echo "Claude Code UI is running on port $${PORT}"
        break
      fi
      if ! kill -0 $${CCUI_PID} 2>/dev/null; then
        echo "ERROR: Claude Code UI crashed. Log output:"
        cat "$${CODER_HOME}/.claude-code-ui.log" 2>/dev/null || true
        break
      fi
      sleep 2
    done
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


# ── Docker Network ─────────────────────────────────────────────────────────────

resource "docker_network" "wp_network" {
  name     = "coder-${data.coder_workspace.me.id}-wp"
  driver   = "bridge"
  ipv6     = false
  internal = false

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

# ── Persistent Volumes ─────────────────────────────────────────────────────────

resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.id}-home"
  lifecycle { ignore_changes = all }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name_at_creation"
    value = data.coder_workspace.me.name
  }
}

resource "docker_volume" "mysql_volume" {
  name = "coder-${data.coder_workspace.me.id}-mysql"
  lifecycle { ignore_changes = all }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

resource "docker_volume" "wordpress_volume" {
  name = "coder-${data.coder_workspace.me.id}-wordpress"
  lifecycle { ignore_changes = all }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

# ── MySQL Container ────────────────────────────────────────────────────────────

resource "docker_container" "mysql" {
  count   = data.coder_workspace.me.start_count
  image   = "mysql:8.0"
  name    = "coder-${local.username}-${lower(local.workspace_name)}-mysql"
  restart = "unless-stopped"

  env = [
    "MYSQL_ROOT_PASSWORD=${local.mysql_root_pass}",
    "MYSQL_DATABASE=${var.wordpress_db_name}",
    "MYSQL_USER=${var.wordpress_db_user}",
    "MYSQL_PASSWORD=${local.wp_db_pass}",
  ]

  networks_advanced {
    name    = docker_network.wp_network.name
    aliases = ["mysql"]
  }

  volumes {
    container_path = "/var/lib/mysql"
    volume_name    = docker_volume.mysql_volume.name
    read_only      = false
  }

  # Keep MySQL healthy before WordPress tries to connect
  healthcheck {
    test         = ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p${local.mysql_root_pass}"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 5
    start_period = "30s"
  }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
}

# ── WordPress Container ────────────────────────────────────────────────────────

resource "docker_container" "wordpress" {
  count   = data.coder_workspace.me.start_count
  image   = "wordpress:latest"
  name    = "coder-${local.username}-${lower(local.workspace_name)}-wordpress"
  restart = "unless-stopped"

  env = [
    "WORDPRESS_DB_HOST=mysql:3306",
    "WORDPRESS_DB_NAME=${var.wordpress_db_name}",
    "WORDPRESS_DB_USER=${var.wordpress_db_user}",
    "WORDPRESS_DB_PASSWORD=${local.wp_db_pass}",
    "WORDPRESS_TABLE_PREFIX=wp_",
    "WORDPRESS_CONFIG_EXTRA=define('FS_METHOD', 'direct');",
  ]

  networks_advanced {
    name    = docker_network.wp_network.name
    aliases = ["wordpress"]
  }

  volumes {
    container_path = "/var/www/html"
    volume_name    = docker_volume.wordpress_volume.name
    read_only      = false
  }

  # Mount WordPress files into the agent's home so developers can edit them
  volumes {
    container_path = "/home/coder/wordpress"
    volume_name    = docker_volume.wordpress_volume.name
    read_only      = false
  }

  depends_on = [docker_container.mysql]

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
}

# ── phpMyAdmin Container ───────────────────────────────────────────────────────

resource "docker_container" "phpmyadmin" {
  count   = data.coder_workspace.me.start_count
  image   = "phpmyadmin:latest"
  name    = "coder-${local.username}-${lower(local.workspace_name)}-phpmyadmin"
  restart = "unless-stopped"

  env = [
    "PMA_HOST=mysql",
    "PMA_PORT=3306",
    "PMA_USER=root",
    "PMA_PASSWORD=${local.mysql_root_pass}",
    # Allow login to any server (useful for debugging)
    "PMA_ARBITRARY=1",
    # Upload limit for SQL imports
    "UPLOAD_LIMIT=256M",
    "MAX_EXECUTION_TIME=600",
  ]

  networks_advanced {
    name    = docker_network.wp_network.name
    aliases = ["phpmyadmin"]
  }

  depends_on = [docker_container.mysql]

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
}

# ── Dev image (built from Dockerfile.dev — includes PHP, WP-CLI, Claude, etc.) ─

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

# ── Coder Agent Sidecar (workspace shell container) ───────────────────────────

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = docker_image.dev.image_id
  name  = "coder-${local.username}-${lower(local.workspace_name)}"

  hostname   = data.coder_workspace.me.name
  entrypoint = ["sh", "-c", replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    "MYSQL_ROOT_PASSWORD=${local.mysql_root_pass}",
    "WP_DB_NAME=${var.wordpress_db_name}",
    "WP_DB_USER=${var.wordpress_db_user}",
    "WP_DB_PASSWORD=${local.wp_db_pass}",
  ]

  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }

  networks_advanced {
    name = docker_network.wp_network.name
  }

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home_volume.name
    read_only      = false
  }

  # Mount WordPress files so developers can edit themes/plugins from VS Code
  volumes {
    container_path = "/home/coder/wordpress"
    volume_name    = docker_volume.wordpress_volume.name
    read_only      = false
  }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
}

# ── Outputs ────────────────────────────────────────────────────────────────────

output "mysql_root_password" {
  value       = local.mysql_root_pass
  description = "MySQL root password"
  sensitive   = true
}

output "wordpress_db_password" {
  value       = local.wp_db_pass
  description = "WordPress DB password"
  sensitive   = true
}
