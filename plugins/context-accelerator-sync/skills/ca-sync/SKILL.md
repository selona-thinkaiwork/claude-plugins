---
name: ca-sync
description: >-
  Run Context Accelerator folder sync now and explain the result: conflicts, notices,
  held deletes, files that didn't sync. Use when the user asks to sync, refresh or push
  their Context Accelerator folder, asks why a file didn't sync, asks about a
  .conflict or .local-edit file or _SYNC-NOTICES.md, or asks for the sync status.
---

# Context Accelerator sync: run and explain

The plugin's script does all the work: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ca-sync"`
(on Windows without bash: `${CLAUDE_PLUGIN_ROOT}\scripts\ca-sync.cmd`). File contents never
pass through you. Don't copy, upload or download synced files yourself.

- **Sync now:** `... run`. It prints one line, for example:
  `OK device=Priya-laptop trigger=manual folders=3 pull=2 push=1 conflicts=0 deletes=0 held_deletes=0 skipped=0 failed=0 notices=0`
  Say it in plain words ("2 files came down, 1 went up").
- **Status:** `... status` shows the folder, device, server, whether the token is stored, the
  last run and where `sync.log` is.
- If sync isn't set up yet (exit 1, "isn't set up"), use the `ca-sync-setup` skill.

## Explaining what the user sees

| They see | What happened | What to do |
|---|---|---|
| `name.conflict-<time>.ext` | The file changed here and on the platform. The platform copy is in place; theirs is the `.conflict` file. | Compare the two, keep what they want in the original name, delete the other. The next sync sends it up. |
| `name.local-edit-<time>.ext` | They edited a file they can't change (parent context needs an organisation admin; archived usecases are read-only). Their edit is kept; the platform version is back. | Ask an admin, or copy their change into a file they own. |
| `_SYNC-NOTICES.md` | Messages from sync that need a person. | Read the newest entries, act on them, then delete the file. |
| "N deletions are on hold" | More than 25 files were deleted in one usecase in one go, so nothing was deleted. | Ask whether they meant it. If not, run `... restore-held`: the files come back down. If they did, a Context Accelerator admin approves the deletes for this device (the next sync then carries them out). |
| "looks empty or moved" | A usecase folder that synced before is empty. Nothing was deleted on the platform. | If they moved the root folder, run setup again pointing at the new place. |
| A file skipped as "in use" | It was open in Excel/Word. | Close it; it syncs on the next run. |
| "too long for Windows" | Root folder + file path is over the Windows limit. | Move the sync folder somewhere shorter and run setup again. |

## Rules worth knowing

- Edits to `context/` files are **company-wide**: every usecase gets the new version.
- Editing a skill, input or output that other usecases share makes a copy for this
  usecase; the others keep theirs.
- `CLAUDE.md` and `.claude/settings.json` can be edited. Sync keeps the edit as this
  usecase's custom version. Deleting the file brings back the generated one.
  `settings.json` must stay valid JSON or the edit is refused.
- Files deleted on the platform go to `.ca-sync/trash/<date>/` locally, kept 30 days.
- Ignored and never synced: `.DS_Store`, `Thumbs.db`, `desktop.ini`, `~$*` Office lock
  files, `*.tmp`, conflict and local-edit copies, `_SYNC-NOTICES.md`.
- Files over 250 MB don't sync; upload them in the web app.

## Exit codes

0 synced · 2 synced but something needs a human · 3 device disconnected (offer
"reconnect sync") · 4 server unreachable or sync turned off (nothing changed) · 5 plugin
too old · 1 not set up or a local error.
