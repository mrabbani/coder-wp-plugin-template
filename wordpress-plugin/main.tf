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

variable "wordpress_port" {
  default     = 8080
  description = "Host port for WordPress"
  type        = number
}

variable "phpmyadmin_port" {
  default     = 8081
  description = "Host port for phpMyAdmin"
  type        = number
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
    set -e

    # First-run skeleton copy
    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~
      touch ~/.init_done
    fi

    # Print connection info to the workspace log
    echo "============================================"
    echo " WordPress  → http://localhost:${var.wordpress_port}"
    echo " phpMyAdmin → http://localhost:${var.phpmyadmin_port}"
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

  # ── Dashboard metadata ────────────────────────────────────────────────────

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
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "WordPress Status"
    key          = "4_wp_status"
    script       = "curl -sf -o /dev/null -w 'HTTP %%{http_code}' http://wordpress:80 || echo 'unreachable'"
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
  url          = "http://localhost:${var.wordpress_port}"
  icon         = "https://upload.wikimedia.org/wikipedia/commons/thumb/9/98/WordPress_blue_logo.svg/1200px-WordPress_blue_logo.svg.png"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url      = "http://localhost:${var.wordpress_port}"
    interval = 15
    threshold = 6
  }
}

resource "coder_app" "phpmyadmin" {
  agent_id     = coder_agent.main.id
  slug         = "phpmyadmin"
  display_name = "phpMyAdmin"
  url          = "http://localhost:${var.phpmyadmin_port}"
  icon         = "https://www.phpmyadmin.net/static/favicon.ico"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url      = "http://localhost:${var.phpmyadmin_port}"
    interval = 15
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

# ── Docker Network ─────────────────────────────────────────────────────────────

resource "docker_network" "wp_network" {
  name = "coder-${data.coder_workspace.me.id}-wp"

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
  ]

  ports {
    internal = 80
    external = var.wordpress_port
  }

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

  ports {
    internal = 80
    external = var.phpmyadmin_port
  }

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

# ── Coder Agent Sidecar (workspace shell container) ───────────────────────────

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = "codercom/enterprise-base:ubuntu"
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

output "wordpress_url" {
  value       = "http://localhost:${var.wordpress_port}"
  description = "WordPress site URL"
}

output "phpmyadmin_url" {
  value       = "http://localhost:${var.phpmyadmin_port}"
  description = "phpMyAdmin URL"
}

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
