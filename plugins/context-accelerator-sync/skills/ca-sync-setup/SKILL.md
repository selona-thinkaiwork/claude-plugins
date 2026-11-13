---
name: ca-sync-setup
description: >-
  One-time setup (or reconnect) of Context Accelerator folder sync on this computer:
  picks the company and a local folder, connects this device, runs the first sync and
  creates the hourly scheduled task. Use when the user says "set up Context Accelerator
  sync", "sync my usecases to a folder", "connect this computer to Context Accelerator",
  or "reconnect sync" (after a "disconnected" message or exit code 3).
---

# Set up Context Accelerator sync

After setup, a folder on this computer mirrors every usecase of one company, two ways:
edits made here go to the platform, and platform changes come down. The work is done by
the plugin's script; you only run it and report what it says. **Never read, copy or
modify the synced files yourself during setup.**

The script is `${CLAUDE_PLUGIN_ROOT}/scripts/ca-sync`. Run it with `bash`, on Windows too
(Claude Code on Windows uses Git Bash). If bash isn't available on Windows, run
`${CLAUDE_PLUGIN_ROOT}\scripts\ca-sync.cmd` with the same arguments instead.

## Steps

1. **Connector.** Make sure the Context Accelerator connector is signed in. If its tools
   fail with an auth error, ask the user to sign in (a browser window opens) and retry.

2. **Company.** Call `list_companies`. If there is more than one, ask which company
   this computer should sync. One folder holds one company.

3. **Folder.**
   - Propose `~/Documents/ContextAccelerator/<Company>` (Windows:
     `%USERPROFILE%\Documents\ContextAccelerator\<Company>`).
   - **OneDrive check (Windows):** if `Documents` is redirected into OneDrive (the path
     contains `OneDrive`), don't use it, because two sync engines would fight over the
     same files. Propose `%USERPROFILE%\ContextAccelerator\<Company>` instead and say why.
     Do the same for any folder inside iCloud Drive, Dropbox or Google Drive.
   - Keep the full path short (under about 80 characters) so deep files stay within
     Windows' path limit.
   - Ask the user to confirm the folder. If the app asks to allow access to it, approve it.

4. **Connect this device.** Call `create_sync_device_claim(company_id, device_name)` with
   a name like "Priya's laptop" (ask, or use the computer name). It returns a one-time
   `claim_code` that is valid for 10 minutes. Then run:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/ca-sync" setup --claim <claim_code> --root "<folder>"
   ```

   The script trades the code for a device token and stores it in the Keychain or
   Windows' protected storage. The token is never shown, so don't ask for it or try to
   read it. Expect `OK setup device=... company=... root=...` and then
   `OK scheduled runs enabled for <folder>`: setup also puts a copy of the sync script and
   a separate scheduled-run token in the folder's hidden `.ca-sync` directory, which the
   hourly task in step 6 uses. Never read or print `.ca-sync/scheduled-token`.

5. **First sync.** Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ca-sync" run`. The first run
   only downloads. Report the summary line in plain words, e.g. "3 usecase folders,
   41 files downloaded".

6. **Scheduled task (Claude desktop app).** Scheduled tasks run in a Linux virtual
   machine, not in this shell. The VM can't see the plugin folder, the Keychain or
   Windows' protected storage, and it sees the sync folder only once the user connects
   it, under `$HOME/mnt/<folder name>`. That is why setup put the script and a
   scheduled-run token in the folder itself. You can't create this task from Claude
   Code (`/schedule` runs in the cloud and can't reach the folder), so walk the user
   through it in the Claude desktop app, **Settings → Scheduled tasks → New task**:

   1. Run it **every hour** and switch on **Require this computer**.
   2. **Connect the sync folder** `<folder>` to the task.
   3. Paste this prompt, with `<folder>` filled in:

      > Sync my Context Accelerator folder `<folder>`, which is connected to this task and mounted under `$HOME/mnt`.
      > 1. Allow deleting files in `<folder>` (sync replaces and removes files), using your tool for delete permission on a connected folder.
      > 2. In your Linux shell, run: `bash "$(find "$HOME/mnt" -maxdepth 5 -path '*/.ca-sync/bin/ca-sync' | head -n 1)" run --scan "$HOME/mnt" --quiet --trigger scheduled`
      > Do not read or modify any synced files yourself, and never read `.ca-sync/scheduled-token`.
      > If the exit code is 0, stop without comment.
      > If it is 2, read the newest entries in each `_SYNC-NOTICES.md` under `$HOME/mnt` and send me a short summary of what needs my attention.
      > If it is 3, tell me scheduled sync was disconnected and that I should say "reconnect sync" in Claude on this computer.
      > For any other exit code, or if no `ca-sync` was found under `$HOME/mnt`, run it again without `--quiet` and tell me in one line what it printed, and stop.

   4. **Switch on automatic approval** in the task's settings. Say this as its own step:
      without it the hourly run stops at the first permission prompt and never syncs. If
      their organisation doesn't allow it, their Claude admin has to enable it.
   5. Click **Run now** once. Success is silent; anything else, they paste it to you.

7. **Explain in three lines:**
   - The folder is two-way: edit, add or delete files in any usecase folder and the
     change reaches the platform. Edits to `context/` apply to the whole company.
   - If both sides changed a file, the platform copy wins and theirs is kept beside it
     as a `.conflict-<time>` file. Anything that needs them shows up in `_SYNC-NOTICES.md`.
   - It syncs every hour, when a Claude session starts, and right after Claude edits a
     file there. `/ca-sync` syncs now.

## Reconnect ("reconnect sync", or exit code 3)

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ca-sync" status` and note the device id and
   company id.
2. Call `create_sync_device_claim(company_id, device_name, device_id=<that id>)`. Passing
   `device_id` keeps the device's sync history, so local edits aren't turned into conflicts.
3. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ca-sync" reset-token --claim <claim_code>`, then
   `... run`. Reset-token also renews the scheduled-run token, so the hourly task works
   again without changes.

If only the scheduled task reports exit code 3 while syncing here works, run
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/ca-sync" enable-scheduled`: it issues a new
scheduled-run token (the old one stops working). `disable-scheduled` turns scheduled
runs off for this computer's folders.

## Exit codes

| Code | Meaning | What to say |
|---|---|---|
| 0 | Synced | The summary line, in plain words |
| 2 | Synced, something needs a human | Read `_SYNC-NOTICES.md` and summarise |
| 3 | Device disconnected | Offer to reconnect |
| 4 | Server unreachable, or sync turned off | One line; nothing was changed locally |
| 5 | Plugin too old | Ask them to update the plugin |
| 1 | Not set up / local error | Show the message |
