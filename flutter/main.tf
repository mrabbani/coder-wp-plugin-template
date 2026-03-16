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
  default     = "/home/ubuntu/flutter-projects"
  description = "Host path where the Flutter project is stored"
}

# ── Parameters (user-facing at workspace creation) ───────────────────────────

data "coder_parameter" "repo_url" {
  name         = "repo_url"
  display_name = "Git Repo URL"
  description  = "HTTPS URL of the Flutter project repository"
  default      = ""
  mutable      = true
}

data "coder_parameter" "repo_branch" {
  name         = "repo_branch"
  display_name = "Git Branch"
  description  = "Branch to clone"
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

# ── Volumes ──────────────────────────────────────────────────────────────────

resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.id}-home"
  lifecycle { ignore_changes = all }
}

# ── Dev image ────────────────────────────────────────────────────────────────

resource "docker_image" "dev" {
  name = "flutter-dev-${data.coder_workspace.me.id}"
  build {
    context    = path.module
    dockerfile = "Dockerfile.dev"
    build_args = {
      FLUTTER_CHANNEL = var.flutter_channel
      JAVA_VERSION    = var.java_version
    }
  }
  triggers = {
    dockerfile      = filemd5("${path.module}/Dockerfile.dev")
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

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    "GIT_TOKEN=${var.git_token}",
    "REPO_URL=${data.coder_parameter.repo_url.value}",
    "REPO_BRANCH=${data.coder_parameter.repo_branch.value}",
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

    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~ 2>/dev/null || true
      touch ~/.init_done
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Flutter Mobile Dev Workspace"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    sudo chown -R coder:coder "$WORKSPACE" 2>/dev/null || true

    REPO_URL="$${REPO_URL:-}"
    REPO_BRANCH="$${REPO_BRANCH:-main}"

    if [ -n "$${GIT_TOKEN:-}" ] && [ -n "$REPO_URL" ]; then
      git config --global credential.helper store
      HOST=$(echo "$REPO_URL" | sed -E 's|https://([^/]+)/.*|\1|')
      echo "https://oauth2:$${GIT_TOKEN}@$${HOST}" >> ~/.git-credentials
      chmod 600 ~/.git-credentials 2>/dev/null || true
    fi

    # Clone repo
    if [ -n "$REPO_URL" ]; then
      REPO_NAME=$(basename "$REPO_URL" .git)
      PROJECT_DIR="$WORKSPACE/$REPO_NAME"

      if [ ! -d "$PROJECT_DIR/.git" ]; then
        echo "Cloning $REPO_URL (branch: $REPO_BRANCH)..."
        git clone --branch "$REPO_BRANCH" --single-branch "$REPO_URL" "$PROJECT_DIR" 2>&1 | tail -3 || true
      else
        git -C "$PROJECT_DIR" pull --ff-only 2>&1 | tail -3 || true
      fi

      [ -f "$PROJECT_DIR/pubspec.yaml" ] && (cd "$PROJECT_DIR" && flutter pub get 2>&1 | tail -5) || true
    fi

    echo ""
    flutter doctor 2>&1 || true

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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
    display_name = "Flutter Version"
    key          = "flutter_version"
    script       = "flutter --version | head -1"
    interval     = 60
    timeout      = 10
  }

  metadata {
    display_name = "Dart Version"
    key          = "dart_version"
    script       = "dart --version 2>&1"
    interval     = 60
    timeout      = 5
  }
}

# ── Apps ──────────────────────────────────────────────────────────────────────

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
