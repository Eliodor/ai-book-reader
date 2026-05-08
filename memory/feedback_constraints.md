---
name: feedback_constraints
description: Non-negotiable runtime constraints for AI Book Reader — Dart-only, on-device only, mobile-first, Python repo is read-only reference.
type: feedback
---

Four non-negotiable constraints govern all architectural choices:

1. **Dart/Flutter only.** No Python, no FFI/C++ beyond what Anx already ships, no external binaries, no `tools/translator/` or `scripts/python/` folders.
2. **On-device only.** No user-hosted backend, no "do heavy work on PC and sync." LLM calls go from device direct to provider.
3. **Mobile-first.** If a solution only works on desktop (heavy CPU, keyboard) — rethink or defer. Desktop comes free from Flutter, but is not optimized for.
4. **Python repo (`D:\Projects\NovelTranslator`) is a read-only artifact.** Nothing is copied verbatim. After migration completes, that repo can be deleted.

**Why:** User explicitly framed these as "non-negotiable" in the onboarding brief; violating them = redo the plan. Performance pressure on phones is acceptable cost for shipping fully on-device.

**How to apply:** Before suggesting any code that introduces Python, FFI, an external service, or a desktop-only assumption — stop and rethink. Heavy ops belong in Isolates with foreground service + notification on Android, with resumable progress; on iOS the app must stay open and the UI should say so honestly. Battery-aware pausing is in scope.
