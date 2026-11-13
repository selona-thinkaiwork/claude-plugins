---
description: Show Context Accelerator sync status for this computer
allowed-tools: Bash
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ca-sync" status` (on Windows without bash:
`${CLAUDE_PLUGIN_ROOT}\scripts\ca-sync.cmd status`) and summarise it: which folder syncs
which company, the device name, when it last ran and what happened, whether the token is
stored, how many folders have unread `_SYNC-NOTICES.md`, and where `sync.log` is. Don't
print the device token (the script never shows it).
