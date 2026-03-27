# Laravel + Flutter — Coder Workspace Template

A batteries-included [Coder](https://coder.com) workspace template for full-stack development with a **Laravel** API backend and **Flutter** mobile frontend, plus **Claude Code** AI assistance.

---

## What's Included

| Service | Access | Purpose |
|---|---|---|
| Laravel API | Coder dashboard button | Backend dev server (port 8000) |
| VS Code | Coder dashboard button | Browser IDE (code-server) |
| phpMyAdmin | Coder dashboard button | Database GUI |
| Claude Code | Terminal: `claude` | AI pair-programmer |

### Tools pre-installed
- **PHP** (8.1 / 8.2 / 8.3 — your choice) + Composer
- **Flutter SDK** (stable / beta / dev channel)
- **Dart SDK** — included with Flutter
- **Android SDK** — command-line tools, platform-tools, build-tools 34
- **JDK** (17 / 21) — required for Android builds
- **Node / npm** — frontend asset toolchain (Vite, PostCSS)
- **MySQL 8.0** — database
- **Redis 7** — cache & session driver
- **Claude Code** — AI assistant
- **GitHub CLI (`gh`)** — clone, pull, push, and manage PRs from the terminal
- **code-server** — VS Code with PHP, Laravel, Dart & Flutter extensions

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

    workspace/
    ├── backend/     ← Laravel API
    └── mobile/      ← Flutter app
```

All services run in Docker containers on a shared network.

---

## Deploy to Coder

```bash
# 1. Push the template
coder templates push laravel-flutter \
  --directory ./laravel-flutter \
  --yes

# 2. Create a workspace
coder create my-fullstack \
  --template laravel-flutter

# 3. Open the workspace
coder open my-fullstack
```

---

## Template Variables (set when pushing template)

| Variable | Description | Default |
|---|---|---|
| `git_token` | Git PAT for cloning private repos | (empty) |
| `php_version` | PHP version | `8.2` |
| `flutter_channel` | Flutter channel | `stable` |
| `java_version` | JDK version | `17` |
| `project_base_path` | Host path for project storage | `/home/ubuntu/laravel-flutter-projects` |

No user-facing parameters — workspace starts immediately with all services ready. Clone your repos manually into `workspace/`.

---

## Claude Code & GitHub CLI Login

### Claude Code

```bash
# Login (uses OAuth — opens browser or paste token)
claude login

# Start interactive session
claude

# One-shot tasks
claude "add an API endpoint for user authentication"
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

## Startup Behavior

1. Fixes volume permissions
2. Configures Git credentials (if `git_token` provided)
3. Waits for MySQL
4. Runs `flutter doctor`
5. Starts phpMyAdmin and code-server

---

## Common Commands

### Backend (Laravel)

```bash
cd backend/

php artisan serve --host=0.0.0.0 --port=8000
php artisan migrate
php artisan make:model Post -mcr
php artisan tinker
php artisan queue:work
php artisan test

composer require laravel/sanctum
npm run dev          # Vite dev server
npm run build        # Production build
```

### Mobile (Flutter)

```bash
cd mobile/

flutter pub get
flutter run                    # Run on connected device/emulator
flutter build apk              # Build Android APK
flutter build appbundle        # Build Android App Bundle
flutter test                   # Run tests
flutter analyze                # Static analysis

dart format .                  # Format code
dart fix --apply               # Apply suggested fixes
dart run build_runner build --delete-conflicting-outputs
```

---

## Troubleshooting

### "Peer is not connected"
The Coder agent can't reach the Coder server. The template maps `host.docker.internal` to the host gateway — verify Docker's `host-gateway` resolves correctly on your server.

### MySQL timeout
Verify the MySQL container is running: `docker ps --filter "name=mysql-"`

### Flutter doctor warnings
Run `flutter doctor -v` for detailed diagnostics. Android license warnings can be resolved with `flutter doctor --android-licenses`.

### Permission denied on workspace files
The startup script runs `chown -R coder:coder` to fix host-mounted volume permissions. If it fails, check that the host path exists.

---

## License

MIT
