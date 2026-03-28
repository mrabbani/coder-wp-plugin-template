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
      NODE_MAJOR      = data.coder_parameter.node_version.value
    }
  }
  triggers = {
    dockerfile      = filemd5("${path.module}/Dockerfile.dev")
    flutter_channel = var.flutter_channel
    java_version    = var.java_version
    node_version    = data.coder_parameter.node_version.value
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

  entrypoint = ["sh", "-c", replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]
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
    echo "  Flutter Mobile Dev Workspace"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    sudo chown -R coder:coder /home/coder 2>/dev/null || true
    sudo chmod -R 775 /home/coder/workspace 2>/dev/null || true

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
    flutter doctor >/tmp/flutter-doctor.log 2>&1 || true

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

  metadata {
    display_name = "Node.js Version"
    key          = "node_version"
    script       = "node --version"
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
