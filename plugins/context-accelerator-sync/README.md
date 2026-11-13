# Context Accelerator Sync (plugin)

Two-way sync between a company's Context Accelerator usecases and a local folder, run by
Claude. Sync v4: the server decides every action; the scripts here only hash files,
transfer bytes and report back.

| Piece | Path |
|---|---|
| Setup skill (one-time, reconnect) | `skills/ca-sync-setup/SKILL.md` |
| Run/explain skill | `skills/ca-sync/SKILL.md` |
| `/ca-sync`, `/ca-sync-status` | `commands/` |
| Hooks: SessionStart, PostToolUse (Write/Edit) | `hooks/hooks.json` |
| Launcher (picks the script per OS, runs hooks in the background) | `scripts/ca-sync`, `scripts/ca-sync.cmd` |
| Windows client (PowerShell 5.1, DPAPI) | `scripts/ca-sync.ps1` |
| macOS client (bash 3.2, Keychain) | `scripts/ca-sync.sh` |
| Server the scripts talk to | `scripts/server-url` |
| Connector | `.mcp.json` |

**Release checklist:** `scripts/server-url` and `.mcp.json` point at the dev server
(`dev-api.selona.ai`). Change both for a production release, bump `VERSION` and
`.claude-plugin/plugin.json`, add a `CHANGELOG.md` entry.

**Debugging:** `CA_SYNC_DEBUG=1` prints a stack trace on errors (Windows);
`CA_SYNC_FOREGROUND=1` runs hooks in the foreground. Logs: `<root>/.ca-sync/sync.log`.

**Server side:** `backend/app/services/sync_v4/` (planner, engine, remote, devices),
`backend/app/api/v1/sync_v4.py`. Needs `SYNC_V4_ENABLED=true` and the organisation's
`settings.sync_v4 = true`.
