# Flutter Mobile Dev — Coder Workspace Template

A batteries-included [Coder](https://coder.com) workspace template for Flutter mobile app development with **Claude Code** AI assistance.

---

## What's Included

| Service | Access | Purpose |
|---|---|---|
| VS Code | Coder dashboard button | Browser IDE (code-server) |
| Claude Code | Terminal: `claude` | AI pair-programmer |

### Tools pre-installed
- **Flutter SDK** (stable / beta / dev channel — your choice)
- **Dart SDK** — included with Flutter
- **Android SDK** — command-line tools, platform-tools, build-tools 34
- **JDK** (17 / 21 — your choice) — required for Android builds
- **Claude Code** — AI assistant
- **code-server** — VS Code in the browser with Dart & Flutter extensions

---

## Architecture

```
                    Coder Server (:3000)
                         |
                    Coder Agent (dev container)
                         |
                    code-server:8081
                         |
              Flutter SDK + Android SDK + Dart
```

Single container setup — no databases or extra services needed.

---

## Deploy to Coder

```bash
# 1. Push the template
coder templates push flutter \
  --directory ./flutter \
  --yes

# 2. Create a workspace
coder create my-flutter \
  --template flutter

# 3. Open the workspace
coder open my-flutter
```

---

## Template Parameters

| Parameter | Description | Default |
|---|---|---|
| `repo_url` | HTTPS URL of the Flutter project repo | (empty) |
| `repo_branch` | Branch to clone | `main` |

## Template Variables (set when pushing template)

| Variable | Description | Default |
|---|---|---|
| `git_token` | Git PAT for cloning private repos | (empty) |
| `flutter_channel` | Flutter channel | `stable` |
| `java_version` | JDK version | `17` |
| `project_base_path` | Host path for project storage | `/home/ubuntu/flutter-projects` |

---

## Startup Behavior

1. Fixes volume permissions
2. Configures Git credentials (if `git_token` provided)
3. Clones repo into `workspace/<repo-name>` (if not already cloned), or pulls latest
4. Runs `flutter pub get` if `pubspec.yaml` exists
5. Runs `flutter doctor` to verify toolchain
6. Starts code-server

---

## Common Commands

```bash
# Flutter
flutter pub get
flutter run                    # Run on connected device/emulator
flutter build apk              # Build Android APK
flutter build appbundle        # Build Android App Bundle
flutter build ios              # Build iOS (requires macOS)
flutter test                   # Run tests
flutter analyze                # Static analysis

# Dart
dart format .                  # Format code
dart fix --apply               # Apply suggested fixes

# Code generation (if using build_runner)
dart run build_runner build --delete-conflicting-outputs
dart run build_runner watch

# Android
flutter devices               # List connected devices
flutter emulators              # List available emulators
```

---

## Notes

- **Android builds** work fully (APK/AAB). iOS builds require macOS and are not supported in this Linux container.
- **Physical device debugging** requires USB passthrough or wireless debugging, which may need additional Docker configuration.
- **Web builds** work out of the box: `flutter run -d web-server --web-port=8080`

---

## Troubleshooting

### "Peer is not connected"
The Coder agent can't reach the Coder server. The template maps `host.docker.internal` to the host gateway — verify Docker's `host-gateway` resolves correctly on your server.

### Flutter doctor warnings
Run `flutter doctor -v` for detailed diagnostics. Android license warnings can be resolved with `flutter doctor --android-licenses`.

### Permission denied on workspace files
The startup script runs `chown -R coder:coder` to fix host-mounted volume permissions. If it fails, check that the host path exists.

---

## License

MIT
