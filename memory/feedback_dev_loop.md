---
name: Dev loop — hot reload, never full APK rebuild
description: For verifying Dart-side changes, use `flutter run` + hot reload/restart, not `flutter build apk`. Each full APK build is 10-15 minutes and the user explicitly objected.
type: feedback
---

For verifying Dart-side iteration work (DAOs, models, providers, services, UI), do **not** run `flutter build apk --debug` followed by `adb install` for every change. Use `flutter run -d R5CY604D5BV` once per session and rely on hot reload (`r`) / hot restart (`R`).

**Why:** during Iteration 2 the agent ran a full APK build for a tiny schema change. The user asked: "получается что для каждой мелкой правки надо ждать 10-15 минут на билд. Должен же быть какой-то хот релоад". Full builds for non-native changes are wasted time.

**How to apply:**
- Default verification flow: `flutter analyze` on touched files → `flutter run -d <device>` once → hot reload / restart for subsequent changes.
- `r` (hot reload, ~1s) — pure Dart changes that don't reset state.
- `R` (hot restart, ~3s) — after `dart run build_runner build`, after schema-relevant changes that need fresh DB state, after changes to `main()` / top-level providers.
- Schema migration verification: `adb shell pm clear io.github.eliodor.aibookreader` + `R` to force `onCreate` / `onUpgrade` to re-run on a clean DB.
- A full `flutter build apk` / reinstall is needed **only** when `pubspec.yaml`, native `android/`, `ios/`, `windows/`, or `AndroidManifest.xml` changed.
- If `flutter run` is impractical from this shell (interactive), prefer Windows desktop target (`flutter run -d windows`) — once the ATL component is installed in VS Build Tools, hot reload on desktop is ~3 seconds end-to-end and faster to drive non-interactively.

If you must verify on-device DB shape without a running session, pull the file with `adb exec-out run-as <pkg> cat ./databases/app_database.db > /tmp/x.db` (binary-safe, unlike `adb shell cat`) and inspect with Python `sqlite3`.
