---
description: Sync the Context Accelerator folder now
allowed-tools: Bash
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ca-sync" run --trigger manual` (on Windows without
bash: `${CLAUDE_PLUGIN_ROOT}\scripts\ca-sync.cmd run --trigger manual`).

Don't read or change any synced files yourself. Report the summary line in plain words.
If the exit code is 2, read the newest entries in the `_SYNC-NOTICES.md` files it mentions
and summarise what needs attention, using the ca-sync skill to explain conflicts, held
deletes and refused edits. Exit 3: offer to reconnect (ca-sync-setup skill). Exit 1 with
"isn't set up": offer to set it up.
