#!/usr/bin/env bash

set -euo pipefail

INSTALL_PATH="${INSTALL_PATH}"
PORT="${PORT}"
INIT_DB="${INIT_DB}"

# Expand home if it's specified
INSTALL_PATH="$${INSTALL_PATH/#\~/$${HOME}}"

echo "Installing Claude Code UI..."

# Check if node is installed
if ! command -v node > /dev/null; then
    echo "Node.js is not installed! Please install Node.js first."
    exit 1
fi

# Check if npm is installed
if ! command -v npm > /dev/null; then
    echo "npm is not installed! Please install npm first."
    exit 1
fi

# Create install directory if it doesn't exist
mkdir -p "$${INSTALL_PATH}"

# Check if claude-code-ui is already installed
if [ -d "$${INSTALL_PATH}/claudecodeui" ]; then
    echo "Claude Code UI is already installed at $${INSTALL_PATH}/claudecodeui"
    cd "$${INSTALL_PATH}/claudecodeui"
    echo "Pulling latest changes..."
    git pull origin main || echo "Failed to pull latest changes, continuing with existing version"
else
    echo "Cloning claude-code-ui repository..."
    cd "$${INSTALL_PATH}"
    git clone --depth 1 -b main https://github.com/siteboon/claudecodeui.git
    cd claudecodeui
fi

# Install dependencies if node_modules doesn't exist or if package.json is newer
if [ ! -d "node_modules" ] || [ "package.json" -nt "node_modules" ]; then
    echo "Installing dependencies..."
    npm install
fi

# Create the DB file from the base64 content.
# Only create DB file if it doesn't already exist
if [ ! -f "$${HOME}/.claude-code-ui.db" ]; then
    echo "Creating DB file..."
    echo "$${INIT_DB}" | base64 -d > "$${HOME}/.claude-code-ui.db"
fi

echo "Claude Code UI installation completed!"

# Check if claude-code-ui is already running
echo "Starting Claude Code UI in background on port $${PORT}..."

# Create .env file with the specified port and disable auth
# Fix ~/.local/bin is not in path, claude executable lives there.
export PATH="$${HOME}/.local/bin:$${PATH}"
cat > .env << EOF
PORT=$${PORT}
VITE_PORT=5173
NODE_ENV=production
VITE_IS_PLATFORM=true
VITE_CONTEXT_WINDOW=160000
CONTEXT_WINDOW=160000
DATABASE_PATH=$${HOME}/.claude-code-ui.db
EOF

# Start claude-code-ui in background using nohup
export DATABASE_PATH=$${HOME}/.claude-code-ui.db
nohup npm start > "$${HOME}/.claude-code-ui.log" 2>&1 &
echo $! > "$${HOME}/.claude-code-ui.pid"
echo "Claude Code UI started in background with PID $(cat "$${HOME}/.claude-code-ui.pid")"
echo "Log file: $${HOME}/.claude-code-ui.log"
echo "Access at: http://localhost:$${PORT}"

exit 0
