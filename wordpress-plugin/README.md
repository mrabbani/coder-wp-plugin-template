# WordPress Multi-Plugin Dev — Coder Workspace Template

A batteries-included [Coder](https://coder.com) workspace template for WordPress multi-plugin development with **Claude Code** AI assistance.

---

## What's Included

| Service | Access | Purpose |
|---|---|---|
| WordPress | Coder dashboard button | Live dev site (admin / admin) |
| VS Code | Coder dashboard button | Browser IDE (code-server) |
| phpMyAdmin | Coder dashboard button | Database GUI |
| Claude Code | Terminal: `claude` | AI pair-programmer |

### Tools pre-installed
- **PHP** (8.1 / 8.2 / 8.3 — your choice)
- **WP-CLI** — WordPress management from the terminal (runs via Docker exec into WP container)
- **Composer** — PHP dependency management + PSR-4 autoloading
- **@wordpress/scripts** — official WP JS/CSS build toolchain
- **PHPUnit + WP_Mock** — unit testing
- **PHP_CodeSniffer + WPCS** — WordPress coding standards linting
- **Claude Code** — installed via [official Coder module](https://registry.coder.com/modules/claude-code) with OAuth support
- **GitHub CLI (`gh`)** — clone, pull, push, and manage PRs from the terminal
- **code-server** — VS Code in the browser with PHP + WP extensions

---

## Architecture

```
                    Coder Server (:3000)
                         |
                    Coder Agent (dev container)
                    /    |    \
    code-server:8081  socat:8080  phpMyAdmin:8082
                         |
                   WordPress:80 (Apache)
                         |
                    MySQL:3306
```

All services run in Docker containers on a shared network. The dev container communicates with WordPress via a `socat` IPv4 proxy to avoid Docker's IPv6 DNS issues.

---

## Deploy to Coder

```bash
# 1. Clone this repo
git clone https://github.com/mrabbani/coder-wp-plugin-template
cd coder-wp-plugin-template

# 2. Push the template to your Coder instance
coder templates push wordpress-plugin \
  --directory . \
  --yes

# 3. Create a workspace
coder create my-plugin \
  --template wordpress-plugin

# 4. Open the workspace
coder open my-plugin
```

---

## Claude Code Authentication

Claude Code supports three authentication methods (in priority order):

### 1. User OAuth Token (Pro/Max subscription — recommended)

On your local machine:
```bash
claude setup-token
```

Copy the token and paste it into the **"Claude Code OAuth Token (User)"** parameter when creating or updating your workspace.

### 2. System OAuth Token (template-level)

Set once when pushing the template:
```bash
coder templates push wordpress-plugin \
  --directory . \
  --variable claude_code_oauth_token=YOUR_TOKEN
```

### 3. API Key

For API users with an `sk-ant-...` key:
```bash
coder templates push wordpress-plugin \
  --directory . \
  --variable anthropic_auth_token=sk-ant-...
```

Or set in Coder admin: **Templates > Settings > Variables**

---

## Claude Code Usage

Claude Code is available in the integrated terminal:

```bash
# Start interactive session
claude

# One-shot tasks
claude "add a REST API endpoint that returns all posts for this plugin"
claude "write a PHPUnit test for the Activator class"
claude "add a settings page with a text field and checkbox"

# Code review
claude "review my plugin for WordPress coding standards issues"
claude "check for security issues: missing nonces, unescaped output"
```

The `CLAUDE.md` file in your workspace root is auto-generated with plugin context.

---

## GitHub CLI Login & Usage

GitHub CLI (`gh`) is pre-installed. Authenticate to clone private repos, push code, and manage pull requests.

```bash
# Login (interactive — choose GitHub.com, HTTPS, and paste a token or use browser auth)
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

## Template Parameters

| Parameter | Description | Default |
|---|---|---|
| `plugins` | JSON array of plugins to clone `[{slug, url, branch}]` | example plugin |
| `plugins_base_path` | Host path where plugin repos are cloned | `/home/ubuntu/plugins` |
| `coder_access_url` | URL containers use to reach Coder server | `http://178.104.53.153:3000` |
| `agent_arch` | CPU architecture (amd64 / arm64) | amd64 |
| `php_version` | PHP version (8.1 / 8.2 / 8.3) | 8.2 |
| `wp_version` | WordPress version | latest |
| `claude_code` | Install Claude Code | true |
| `user_claude_code_oauth_token` | Personal OAuth token from `claude setup-token` | (empty) |

## Template Variables (Secrets)

Set these when pushing the template or in Coder admin:

| Variable | Description | Required |
|---|---|---|
| `claude_code_oauth_token` | System-level Claude Code OAuth token | No |
| `anthropic_auth_token` | Anthropic API key (`sk-ant-...`) | No |
| `git_token` | Git PAT for cloning private repos | No |

---

## Plugin Structure

```
workspace/
├── plugin-one/                 # Each plugin is cloned into its own directory
│   ├── plugin-slug.php         # Main entry point & constants
│   ├── composer.json           # PHP deps & scripts
│   ├── package.json            # JS/CSS build via @wordpress/scripts
│   ├── phpunit.xml             # Test configuration
│   ├── includes/               # Core PHP (PSR-4 autoloaded)
│   ├── admin/                  # Admin-facing code
│   ├── public/                 # Front-end code
│   ├── src/                    # JS/SCSS source
│   ├── languages/              # i18n files
│   └── tests/                  # PHPUnit tests
├── plugin-two/
└── CLAUDE.md                   # Auto-generated project context
```

---

## Common Commands

```bash
# Asset development
npm run start          # Watch & rebuild on change
npm run build          # Production build

# Testing
composer test          # Run PHPUnit
composer lint          # Check WordPress coding standards
composer lint:fix      # Auto-fix coding standard issues

# WP-CLI (runs inside WordPress container via Docker)
wp plugin list
wp post create --post_title="Test" --post_status=publish
wp user list
wp cache flush

# Database
wp db export backup.sql
wp db import backup.sql
wp search-replace 'old-url' 'new-url'
```

---

## Troubleshooting

### "Peer is not connected"
The Coder agent can't reach the Coder server. Check that `coder_access_url` is reachable from inside Docker containers. Try `http://172.17.0.1:3000` (Docker bridge gateway) if the public IP doesn't work.

### "502 Bad Gateway" on WordPress
Docker DNS resolves container hostnames to IPv6, but Apache only listens on IPv4. The template uses a `socat` IPv4 proxy to work around this. Check the agent startup logs for "WordPress proxy" confirmation.

### MySQL timeout
Verify the MySQL container is running: `docker ps --filter "name=mysql-"`

### Permission denied on workspace files
The workspace volume is mounted from the host as root. The startup script runs `chown -R coder:coder` to fix this. If it fails, check that the host path exists and is accessible.

---

## License

GPL v2 or later — [https://www.gnu.org/licenses/gpl-2.0.html](https://www.gnu.org/licenses/gpl-2.0.html)
