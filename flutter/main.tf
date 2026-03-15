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
  display_name = "Git Repository URL"
  description  = "HTTPS URL of the Flutter project repository"
  default      = ""
  mutable      = true
}

data "coder_parameter" "repo_branch" {
  name         = "repo_branch"
  display_name = "Repository Branch"
  description  = "Branch to clone"
  default      = "main"
  mutable      = true
}

data "coder_parameter" "project_base_path" {
  name         = "project_base_path"
  display_name = "Project Base Path (Host)"
  description  = "Absolute path on Coder server where the Flutter project is stored"
  default      = "/home/ubuntu/flutter-projects"
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

data "coder_parameter" "flutter_channel" {
  name         = "flutter_channel"
  display_name = "Flutter Channel"
  default      = "stable"
  mutable      = false
  option {
    name  = "Stable"
    value = "stable"
  }
  option {
    name  = "Beta"
    value = "beta"
  }
  option {
    name  = "Dev"
    value = "dev"
  }
}

data "coder_parameter" "java_version" {
  name         = "java_version"
  display_name = "Java/JDK Version"
  default      = "17"
  mutable      = false
  option {
    name  = "JDK 17"
    value = "17"
  }
  option {
    name  = "JDK 21"
    value = "21"
  }
}

# ── Workspace ────────────────────────────────────────────────────────────────

data "coder_workspace"       "me" {}
data "coder_workspace_owner" "me" {}

# ── Claude config volume ─────────────────────────────────────────────────────

resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.id}-home"
  lifecycle {
    ignore_changes = all
  }
}

resource "docker_volume" "claude_config" {
  name = "claude-config-${data.coder_workspace.me.id}"
}

# ── Dev container ─────────────────────────────────────────────────────────────

resource "docker_image" "dev" {
  name = "flutter-dev-${data.coder_workspace.me.id}"
  build {
    context    = path.module
    dockerfile = "Dockerfile.dev"
    build_args = {
      FLUTTER_CHANNEL = data.coder_parameter.flutter_channel.value
      JAVA_VERSION    = data.coder_parameter.java_version.value
    }
  }
  triggers = {
    dockerfile      = filemd5("${path.module}/Dockerfile.dev")
    flutter_channel = data.coder_parameter.flutter_channel.value
    java_version    = data.coder_parameter.java_version.value
  }
}

resource "docker_container" "dev" {
  count    = data.coder_workspace.me.start_count
  image    = docker_image.dev.image_id
  name     = "flutter-dev-${data.coder_workspace.me.id}"
  hostname = data.coder_workspace.me.name
  restart  = "unless-stopped"

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    "CODER_AGENT_URL=${data.coder_parameter.coder_access_url.value}",
    "GIT_TOKEN=${var.git_token}",
    "REPO_URL=${data.coder_parameter.repo_url.value}",
    "REPO_BRANCH=${data.coder_parameter.repo_branch.value}",
  ]

  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }

  # Persist entire home directory so Mutagen/Coder Desktop can install agents
  volumes {
    volume_name    = docker_volume.home_volume.name
    container_path = "/home/coder"
    read_only      = false
  }

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

  entrypoint = ["sh", "-c", replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]
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

# Prepare user home with default files on first start
if [ ! -f ~/.init_done ]; then
  cp -rT /etc/skel ~ 2>/dev/null || true
  touch ~/.init_done
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Flutter Mobile Dev Workspace"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Step 0: Fix permissions on mounted volumes
sudo chown -R coder:coder "$WORKSPACE" 2>/dev/null || true
sudo chown -R coder:coder /home/coder/.claude 2>/dev/null || true

# Step 1: Git config
git config --global user.email "dev@coder.local"
git config --global user.name  "Coder Dev"

REPO_URL="$${REPO_URL:-}"
REPO_BRANCH="$${REPO_BRANCH:-main}"

if [ -n "$${GIT_TOKEN:-}" ]; then
  git config --global credential.helper store
  if [ -n "$REPO_URL" ]; then
    HOST=$(echo "$REPO_URL" | sed -E 's|https://([^/]+)/.*|\1|')
    echo "https://oauth2:$${GIT_TOKEN}@$${HOST}" >> ~/.git-credentials
  fi
  chmod 600 ~/.git-credentials 2>/dev/null || true
  echo "Git credentials configured"
fi

# Step 2: Clone repo if not exists
if [ -n "$REPO_URL" ]; then
  REPO_NAME=$(basename "$REPO_URL" .git)
  PROJECT_DIR="$WORKSPACE/$REPO_NAME"

  if [ ! -d "$PROJECT_DIR/.git" ]; then
    echo "Cloning $REPO_URL (branch: $REPO_BRANCH)..."
    git clone --branch "$REPO_BRANCH" --single-branch "$REPO_URL" "$PROJECT_DIR" 2>&1 | tail -3 || {
      echo "FAILED to clone $REPO_URL"
    }
  else
    echo "Repository already cloned at $PROJECT_DIR"
    CUR_BRANCH=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "detached")
    echo "  Pulling latest on $CUR_BRANCH..."
    git -C "$PROJECT_DIR" pull --ff-only 2>&1 | tail -3 || echo "  Pull failed (may have local changes)"
  fi

  # Step 3: Flutter pub get
  if [ -f "$PROJECT_DIR/pubspec.yaml" ]; then
    echo "Running flutter pub get..."
    (cd "$PROJECT_DIR" && flutter pub get 2>&1 | tail -5) || true
  fi
else
  echo "No repo URL configured — skipping clone"
fi

# Step 4: Flutter doctor
echo ""
echo "Running flutter doctor..."
flutter doctor 2>&1 || true

# Step 5: Start VS Code — bind to 127.0.0.1 (agent-local, IPv4 only)
echo "Starting VS Code..."
code-server \
  --bind-addr 127.0.0.1:8081 \
  --auth none \
  --disable-telemetry \
  "$WORKSPACE" >/tmp/code-server.log 2>&1 &

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DONE — use app buttons in Coder dashboard"
echo "  Flutter: $(flutter --version --machine 2>/dev/null | head -1 || echo 'installed')"
echo "  Dart:    $(dart --version 2>&1 || echo 'installed')"
echo "  Claude:  claude"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  EOT

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

resource "coder_app" "code_server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "VS Code"
  url          = "http://127.0.0.1:8081?folder=/home/coder/workspace"
  icon         = "/icon/code.svg"
  share        = "owner"
  subdomain    = true
}
