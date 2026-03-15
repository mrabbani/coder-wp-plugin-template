terraform {
    required_version = ">= 1.0"

    required_providers {
        coder = {
            source  = "coder/coder"
            version = ">= 0.12"
        }
    }
}

variable "agent_id" {
    description = "The ID of a Coder agent."
    type        = string
}

variable "port" {
    description = "Port to run claude-code-ui on"
    type        = number
    default     = 13376
}

variable "install_path" {
    description = "Path to install claude-code-ui"
    type        = string
    default     = "$HOME/.claude-code-ui"
}

variable "share" {
    description = "Share mode for the claude-code-ui app"
    type        = string
    default     = "owner"
    validation {
        condition     = contains(["owner", "authenticated", "public"], var.share)
        error_message = "Share must be one of: owner, authenticated, public"
    }
}

resource "coder_script" "claude_code_ui_install" {
    agent_id = var.agent_id
    script = templatefile("${path.module}/run.sh", {
        INSTALL_PATH = var.install_path,
        PORT = var.port,
        INIT_DB = file("${path.module}/init.db.txt")
    })
    display_name       = "Install Claude Code UI"
    icon               = "/emojis/1f4ac.png"
    run_on_start       = true
    start_blocks_login = false
}

resource "coder_app" "claude_code_ui" {
    agent_id     = var.agent_id
    slug         = "ccui"
    display_name = "Claude Code UI"
    icon         = "/emojis/1f4ac.png"
    url          = "http://localhost:${var.port}"
    share        = var.share
    subdomain    = true
    open_in      = "tab"
}

output "install_path" {
    value       = var.install_path
    description = "Path where claude-code-ui is installed"
}

output "port" {
    value       = var.port
    description = "Port claude-code-ui is running on"
}
