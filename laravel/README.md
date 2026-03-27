# Laravel Dev — Coder Workspace Template

A batteries-included [Coder](https://coder.com) workspace template for Laravel development with **Claude Code** AI assistance.

---

## What's Included

| Service | Access | Purpose |
|---|---|---|
| Laravel App | Coder dashboard button | Dev server (port 8000) |
| VS Code | Coder dashboard button | Browser IDE (code-server) |
| phpMyAdmin | Coder dashboard button | Database GUI |
| Claude Code | Terminal: `claude` | AI pair-programmer |

### Tools pre-installed
- **PHP** (8.1 / 8.2 / 8.3 — your choice)
- **Composer** — PHP dependency management
- **Node / npm** — frontend asset toolchain (Vite, PostCSS)
- **MySQL 8.0** — database
- **Redis 7** — cache & session driver
- **Claude Code** — AI assistant
- **GitHub CLI (`gh`)** — clone, pull, push, and manage PRs from the terminal
- **code-server** — VS Code in the browser with Laravel extensions

---

## Architecture

```
                    Coder Server (:3000)
                         |
                    Coder Agent (dev container)
                    /    |    \
    code-server:8081  artisan:8000  phpMyAdmin:8082
                         |
                    MySQL:3306 + Redis:6379
```

All services run in Docker containers on a shared network.

---

## Deploy to Coder

```bash
# 1. Push the template
coder templates push laravel \
  --directory ./laravel \
  --yes

# 2. Create a workspace
coder create my-laravel \
  --template laravel

# 3. Open the workspace
coder open my-laravel
```

---

## Claude Code & GitHub CLI Login

### Claude Code

```bash
# Login (uses OAuth — opens browser or paste token)
claude login

# Start interactive session
claude

# One-shot tasks
claude "add a REST API endpoint for user profiles"
```

### GitHub CLI

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
| `repo_url` | HTTPS URL of the Laravel project repo | (empty) |
| `repo_branch` | Branch to clone | `main` |

## Template Variables (set when pushing template)

| Variable | Description | Default |
|---|---|---|
| `git_token` | Git PAT for cloning private repos | (empty) |
| `php_version` | PHP version | `8.2` |
| `project_base_path` | Host path for project storage | `/home/ubuntu/laravel-projects` |

---

## Startup Behavior

1. Fixes volume permissions
2. Configures Git credentials (if `git_token` provided)
3. Clones repo (if not already cloned), or pulls latest
4. Runs `composer install` and `npm install`
5. Copies `.env.example` → `.env` (if missing) with DB/Redis hosts pre-configured
6. Generates `APP_KEY` if empty
7. Waits for MySQL, then runs `php artisan migrate`
8. Starts Laravel dev server, code-server, and phpMyAdmin

---

## Common Commands

```bash
# Artisan
php artisan serve --host=0.0.0.0 --port=8000
php artisan migrate
php artisan make:model Post -mcr
php artisan tinker
php artisan queue:work

# Testing
php artisan test
php artisan test --filter=UserTest

# Frontend
npm run dev          # Vite dev server
npm run build        # Production build

# Composer
composer require laravel/sanctum
composer test

# Database
php artisan db:seed
php artisan migrate:fresh --seed
```

---

## Troubleshooting

### "Peer is not connected"
The Coder agent can't reach the Coder server. The template maps `host.docker.internal` to the host gateway — verify Docker's `host-gateway` resolves correctly on your server.

### MySQL timeout
Verify the MySQL container is running: `docker ps --filter "name=mysql-"`

### Permission denied on workspace files
The startup script runs `chown -R coder:coder` to fix host-mounted volume permissions. If it fails, check that the host path exists.

---

## License

MIT
