# Context Accelerator Sync: changes

## 4.1.1

- The scheduled task now finds the sync script when you connect the parent of your
  sync folder (for example `ContextAccelerator` instead of `ContextAccelerator/<company>`).
  The setup prompt looked only four folder levels deep and missed it.
- `sync.log` times are now in UTC, marked with `Z`. Runs from the Claude desktop app's
  virtual machine logged UTC and runs on the computer logged local time, so the log
  looked out of order.

## 4.1.0

The hourly sync now works from the Claude desktop app's scheduled tasks, on Windows and
macOS. Those tasks run in a Linux virtual machine that sees only the folders you connect,
so 4.0.0's hourly task couldn't find the script, the settings or the token.

- Setup puts a copy of the sync script and a separate scheduled-run token in the sync
  folder's hidden `.ca-sync` folder. Connecting the sync folder to the task is enough.
  The copy updates itself when the plugin does.
- The scheduled-run token syncs as this computer but can't create tokens. Revoke it on
  its own (`disable-scheduled`, or from the web app); disconnecting the computer revokes
  both. Unlike the computer's own token it's stored as a plain file in the folder,
  because the virtual machine can't read the Keychain or Windows' protected storage.
- `run --scan <dir>` syncs every sync folder found under a directory, using the same
  device details the computer wrote.
- Runs on the computer and in the virtual machine share one lock, so they never overlap.
- New setup steps for the scheduled task (connect the folder, require this computer,
  allow deletes, automatic approval).

## 4.0.0

A new sync that needs nothing but Claude and this plugin. No installer, no background
program of our own, no password stored on your computer.

- Every usecase of your company is a folder on your computer, and it works both ways:
  edit, add or delete files there and the platform follows; platform changes come down.
- Subfolders sync, and so do `context/`, `CLAUDE.md` and `.claude/settings.json`.
- Nothing is lost: if both sides changed a file you get both copies, deleted files go to
  a trash folder for 30 days, and large batches of deletes wait for approval.
- Syncs every hour through a Claude scheduled task, when a session starts, and right
  after Claude edits a file in the folder. `/ca-sync` syncs now.
- Files up to 250 MB.
