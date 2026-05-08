---
name: feedback_branch_policy
description: Branch policy for AI Book Reader — develop mirrors upstream Anx Reader, master is the working branch, do not push to origin without explicit user confirmation.
type: feedback
---

- **`master`** — work branch. All edits, all commits go here.
- **`develop`** — clean mirror of Anxcye/anx-reader upstream. Do **not** commit here directly. Only mechanism: `git fetch upstream && git merge upstream/<their-default-branch>` once every 1-2 months, then merge `develop → master`.
- `origin` is the user's fork on GitHub (`Eliodor/ai-book-reader`); `upstream` may need to be added via `git remote add upstream https://github.com/Anxcye/anx-reader.git` if missing.
- **Do not push to origin without explicit user confirmation.** Local commits also require explicit authorization — see `feedback_no_git_writes.md`.
- The onboarding brief originally said the upstream-mirror branch was "developer", but the actual repo uses `develop` — same intent.

**Why:** User wants the option to track upstream Anx Reader updates without polluting them with rebrand churn or pipeline ports. Pushes to origin are user-visible and may break the user's CI/release flow, so they require explicit consent.

**How to apply:** Always commit to `master`. Never `git checkout develop` to make edits. Never `git push` without user saying so in this session.
