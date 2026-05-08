---
name: feedback_no_git_writes
description: Do not run any state-changing git operations on AI Book Reader; only analytical commands (status, log, diff, show, branch, remote -v) are allowed.
type: feedback
---

Never run write-side git operations on this repo: no `commit`, `add`, `push`, `pull`, `fetch`, `merge`, `rebase`, `checkout`, `branch -d`, `reset`, `stash`, `tag`, `cherry-pick`, `rm`, `mv`, `restore`, `clean`, hook config changes — none.

Only analytical / read-only git is allowed:
- `git status`, `git log`, `git diff`, `git show`, `git blame`
- `git branch -a`, `git remote -v`, `git config --get`

**Why:** User said explicitly mid-session: "не надо ничего комитить, и вообще запрети себе все операции в гит, кроме аналитических." They want full manual control over what lands in `master`, what's staged, and when commits happen. Even reasonable per-substep commits are not authorized. The override stays in effect across sessions.

**How to apply:** When work is finished, leave the working tree dirty. Surface what changed (paths only, no commit suggestion). Tell the user the changes are ready for them to stage/commit themselves. If a future session task is "commit X" or "push Y," confirm with the user before doing it — even after a yes, only execute the specific operation they authorized, scope-limited.
