# Coder Workspace Templates

Batteries-included [Coder](https://coder.com) workspace templates for WordPress, Laravel, Flutter, and full-stack development with **Claude Code** AI assistance.

## Available Templates

| Template | Directory | Description |
|---|---|---|
| WordPress Plugin | `wordpress-plugin/` | Multi-plugin dev with WP-CLI, Composer, phpMyAdmin |
| Laravel | `laravel/` | Laravel API with MySQL, Redis, phpMyAdmin |
| Flutter | `flutter/` | Flutter mobile with Android SDK, Dart |
| Laravel + Flutter | `laravel-flutter/` | Full-stack: Laravel API + Flutter mobile |

---

## Prerequisites

### 1. Install Coder

```bash
curl -fsSL https://coder.com/install.sh | sh
coder server # Starting the Coder Server
```

Or see [Coder install docs](https://coder.com/docs/install) for other methods (Docker, Kubernetes, etc.).

### 2. Login to Coder

```bash
coder login https://your-coder-server-url
```

You'll be prompted to authenticate via browser or token.

### 3. Install Terraform

Coder uses Terraform to provision workspaces. Install it if not already present:

```bash
# Ubuntu/Debian
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

# macOS
brew install terraform
```

Or see [Terraform install docs](https://developer.hashicorp.com/terraform/install).

---

## Clone & Push Templates

```bash
# Clone this repo
git clone https://github.com/mrabbani/coder-wp-plugin-template
cd coder-wp-plugin-template

# Push a template (pick one or push all)
coder templates push wordpress-plugin --directory ./wordpress-plugin --yes

coder templates push laravel --directory ./laravel --yes

coder templates push flutter --directory ./flutter --yes

coder templates push laravel-flutter --directory ./laravel-flutter --yes
```

### Change PHP Version

Templates that include PHP (wordpress-plugin, laravel, laravel-flutter) default to PHP 8.2. You can select the PHP version from a dropdown when creating or updating a workspace — choose from **8.1**, **8.2**, **8.3**, **8.4**, or **8.5**.

### Create a Workspace

```bash
coder create my-workspace --template wordpress-plugin
coder open my-workspace
```

---

## Inside the Workspace

### Claude Code Login

```bash
# Login (uses OAuth -- opens browser or paste token)
claude login

# Start interactive session
claude

# One-shot tasks
claude "help me add a settings page"
```

### GitHub CLI Login

GitHub CLI (`gh`) is pre-installed in all templates.

```bash
# Login (interactive -- choose GitHub.com, HTTPS, paste a token or use browser auth)
gh auth login

# Clone a repo
gh repo clone owner/repo

# Pull & push
git pull
git push

# Pull requests
gh pr create --title "My changes" --body "Description"
gh pr list
gh pr checkout 42
gh pr merge 42
```

---

## License

GPL v2 or later
