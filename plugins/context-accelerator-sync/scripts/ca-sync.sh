#!/bin/bash
# Context Accelerator Sync v4 client for macOS (also runs on Linux / Git Bash).
#
# Deliberately simple: it hashes files, asks the server for a plan, carries the
# plan out and reports back. Every sync decision is made on the server. Uses
# only curl, shasum/sha256sum, stat, find and the macOS Keychain (security),
# so it needs nothing installed. Written for bash 3.2, the version macOS ships.
#
#   ca-sync.sh setup --claim <code> --root <folder> --base <url>
#   ca-sync.sh run [--quiet] [--path <file>] [--trigger <name>]
#   ca-sync.sh hook post-edit | session-start      (reads the hook JSON from stdin)
#   ca-sync.sh status
#   ca-sync.sh restore-held                          (undo deletes held by the safety limit)
#   ca-sync.sh reset-token --claim <code> [--root <folder>]
#   ca-sync.sh enable-scheduled | disable-scheduled  (Claude scheduled tasks; setup enables it)
#   ca-sync.sh run --scan <dir>                      (scheduled task: sync every folder under <dir>)
#
# Exit codes: 0 OK, 2 OK but something needs a human, 3 device disconnected,
# 4 server unreachable or sync turned off, 5 plugin too old, 1 usage/local error.
# The device token lives in the Keychain and is never printed.
#
# Claude's scheduled tasks run in a Linux VM where the computer's token (Keychain
# or DPAPI) can't be read and paths differ. For them, each sync folder holds a
# copy of these scripts in .ca-sync/bin and a separate scheduled-run token in
# .ca-sync/scheduled-token. "run --scan" finds sync folders by their
# .ca-sync/device.json (Windows) or device.env (macOS) and syncs as the same
# device. The lock file is shared with ca-sync.ps1, so runs never overlap.

set -u
CLIENT_VERSION="4.1.2"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_FILES="ca-sync ca-sync.sh ca-sync.ps1 ca-sync.cmd server-url"
UA="ContextAcceleratorSync/$CLIENT_VERSION"
US=$'\037'  # field separator for parsing the server's tab-separated replies

CMD="${1:-run}"
[ $# -gt 0 ] && shift
OPT_CLAIM="" OPT_ROOT="" OPT_BASE="" OPT_PATH="" OPT_TRIGGER="manual" OPT_SCAN="" QUIET=0 REST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet|-quiet) QUIET=1 ;;
    --scan|-scan) OPT_SCAN="${2:-}"; shift ;;
    --claim|-claim) OPT_CLAIM="${2:-}"; shift ;;
    --root|-root) OPT_ROOT="${2:-}"; shift ;;
    --base|-base) OPT_BASE="${2:-}"; shift ;;
    --path|-path) OPT_PATH="${2:-}"; shift ;;
    --trigger|-trigger) OPT_TRIGGER="${2:-}"; shift ;;
    *) REST="$1" ;;
  esac
  shift
done

if [ "$(uname -s)" = "Darwin" ]; then
  APP_DIR="$HOME/Library/Application Support/ContextAcceleratorSync"
  IS_MAC=1
else
  APP_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ContextAcceleratorSync"
  IS_MAC=0
fi
ROOTS_FILE="$APP_DIR/roots"
mkdir -p "$APP_DIR"

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

if stat --version >/dev/null 2>&1; then
  file_stat() { stat -c '%s %Y' "$1"; }
else
  file_stat() { stat -f '%z %m' "$1"; }
fi

if command -v shasum >/dev/null 2>&1; then
  sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  sha_of() { sha256sum "$1" | awk '{print $1}'; }
fi

json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

# -- Token: macOS Keychain; a 0600 file elsewhere ----------------------------

token_save() {
  if [ "$IS_MAC" = 1 ]; then
    security add-generic-password -U -a "$1" -s ContextAcceleratorSync -w "$2" >/dev/null 2>&1
  else
    mkdir -p "$APP_DIR/devices"
    ( umask 077; printf '%s' "$2" > "$APP_DIR/devices/$1.token" )
  fi
}

token_read() {
  if [ "$IS_MAC" = 1 ]; then
    security find-generic-password -a "$1" -s ContextAcceleratorSync -w 2>/dev/null
  else
    cat "$APP_DIR/devices/$1.token" 2>/dev/null
  fi
}

# -- HTTP -----------------------------------------------------------------------
# api METHOD URL BODYFILE OUTFILE [TOKEN] -> prints the HTTP status (000 = unreachable)

api() {
  local method="$1" url="$2" body="$3" out="$4" token="${5:-}" hdr code
  hdr="$(mktemp)"
  chmod 600 "$hdr"
  printf 'User-Agent: %s\nContent-Type: application/json\n' "$UA" > "$hdr"
  [ -n "$token" ] && printf 'Authorization: Bearer %s\n' "$token" >> "$hdr"
  code=$(curl -sS -X "$method" -o "$out" -w '%{http_code}' -H @"$hdr" --data-binary @"$body" "$url" 2>/dev/null) || code="000"
  rm -f "$hdr"
  printf '%s' "${code:-000}"
}

exit_for_status() {
  case "$1" in
    000) say "Sync couldn't reach the server."; return 4 ;;
    401) say "This computer was disconnected from Context Accelerator sync. Say 'reconnect sync' to Claude."; return 3 ;;
    403) say "Sync isn't allowed for this account."; return 3 ;;
    409) return 0 ;;
    426) say "Update the Context Accelerator Sync plugin: this version is too old."; return 5 ;;
    503) say "Sync is turned off on the server right now. Nothing was changed."; return 4 ;;
    *) say "Server error $1."; return 4 ;;
  esac
}

# Authenticated GET/PUT for file transfers; the token goes in a header file, not argv.
auth_curl() {
  local token="$1"; shift
  local hdr rc
  hdr="$(mktemp)"; chmod 600 "$hdr"
  printf 'Authorization: Bearer %s\nUser-Agent: %s\n' "$token" "$UA" > "$hdr"
  curl -fsS -H @"$hdr" "$@" >/dev/null 2>&1; rc=$?
  rm -f "$hdr"
  return $rc
}

# -- Roots and state -----------------------------------------------------------

roots() {
  if [ -n "$OPT_SCAN" ]; then
    find "$OPT_SCAN" -maxdepth 5 -type f \( -path '*/.ca-sync/device.json' -o -path '*/.ca-sync/device.env' \) 2>/dev/null \
      | sed -e 's#/\.ca-sync/device\.[a-z]*$##' | sort -u
    return 0
  fi
  [ -f "$ROOTS_FILE" ] && grep -v '^$' "$ROOTS_FILE"
}

add_root() {
  { roots | grep -vxF "$1"; printf '%s\n' "$1"; } > "$ROOTS_FILE.tmp" 2>/dev/null
  mv -f "$ROOTS_FILE.tmp" "$ROOTS_FILE"
}

json_field() {  # file key -> a top-level string value from the flat JSON ca-sync.ps1 writes
  tr -d '\r\n' < "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\(\([^\"\\\\]\|\\\\.\)*\)\".*/\1/p" \
    | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g'
}

load_device() {  # sets DEVICE_ID DEVICE_NAME BASE_URL COMPANY_ID COMPANY_NAME
  DEVICE_ID="" DEVICE_NAME="" BASE_URL="" COMPANY_ID="" COMPANY_NAME=""
  if [ -f "$1/.ca-sync/device.env" ]; then
    # shellcheck disable=SC1090
    . "$1/.ca-sync/device.env"
    return 0
  fi
  # A folder set up on Windows, synced here by a scheduled task.
  local f="$1/.ca-sync/device.json"
  [ -f "$f" ] || return 1
  DEVICE_ID="$(json_field "$f" device_id)"
  DEVICE_NAME="$(json_field "$f" device_name)"
  BASE_URL="$(json_field "$f" base_url)"
  COMPANY_ID="$(json_field "$f" company_id)"
  COMPANY_NAME="$(json_field "$f" company_name)"
  [ -n "$DEVICE_ID" ] && [ -n "$BASE_URL" ]
}

root_token() {  # root -> the token to sync this folder with
  if [ -n "$OPT_SCAN" ]; then
    cat "$1/.ca-sync/scheduled-token" 2>/dev/null
  else
    token_read "$DEVICE_ID"
  fi
}

install_runner() {  # root: keep .ca-sync/bin at this plugin version
  local bin="$1/.ca-sync/bin" f
  [ -n "$OPT_SCAN" ] && return 0
  [ "$(cd "$bin" 2>/dev/null && pwd)" = "$SELF_DIR" ] && return 0
  [ "$(cat "$bin/VERSION" 2>/dev/null)" = "$CLIENT_VERSION" ] && return 0
  mkdir -p "$bin" || return 0
  for f in $RUNNER_FILES; do
    [ -f "$SELF_DIR/$f" ] && cp -f "$SELF_DIR/$f" "$bin/$f"
  done
  printf '%s' "$CLIENT_VERSION" > "$bin/VERSION"
}

save_device() {
  {
    printf 'DEVICE_ID=%q\n' "$DEVICE_ID"
    printf 'DEVICE_NAME=%q\n' "$DEVICE_NAME"
    printf 'BASE_URL=%q\n' "$BASE_URL"
    printf 'COMPANY_ID=%q\n' "$COMPANY_ID"
    printf 'COMPANY_NAME=%q\n' "$COMPANY_NAME"
  } > "$1/.ca-sync/device.env"
}

# The lock is .ca-sync/lock, the same file ca-sync.ps1 uses, so a scheduled run
# in the VM and a run on the computer never overlap. A lock held by another
# machine is judged by its age only. A scheduled run in the desktop app may not be
# allowed to delete files in the folder, so a released lock can be an empty file:
# an empty lock is free.
lock_host() { local h; h="$(hostname 2>/dev/null)"; printf '%s' "${h:-${HOSTNAME:-ca-sync-sh}}"; }

lock_write() {
  ( set -C; printf '{"pid":%s,"host":%s,"started_at":"%s"}' "$$" "$(json_str "$(lock_host)")" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$1" ) 2>/dev/null
}

lock_overwrite() {
  printf '{"pid":%s,"host":%s,"started_at":"%s"}' "$$" "$(json_str "$(lock_host)")"     "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$1" 2>/dev/null
}

lock_take() {
  local f="$1/.ca-sync/lock" pid host now mtime
  rm -rf "$1/.ca-sync/lock.d" 2>/dev/null  # left by 4.0.0
  lock_write "$f" && return 0
  if [ ! -s "$f" ]; then lock_overwrite "$f"; return; fi
  pid="$(tr -d '\r\n' < "$f" 2>/dev/null | sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
  host="$(json_field "$f" host 2>/dev/null)"
  now=$(date +%s)
  mtime="$(file_stat "$f" 2>/dev/null | awk '{print $2}')"
  if [ $((now - ${mtime:-$now})) -lt 600 ]; then
    if [ -n "$host" ] && [ "$host" != "$(lock_host)" ]; then return 1; fi
    kill -0 "${pid:-0}" 2>/dev/null && return 1
  fi
  lock_overwrite "$f"
}

lock_release() { remove_or_empty "$1/.ca-sync/lock"; }

# Delete a file, or empty it where deleting isn't allowed (a scheduled run in the
# desktop app without delete permission). Readers treat an empty file as absent.
remove_or_empty() { rm -f "$1" 2>/dev/null || : > "$1" 2>/dev/null || true; }

# Copy a working file over a state file in place. mv from the temp folder would
# unlink the old file first, which fails where deleting isn't allowed.
save_state() { [ -f "$1" ] && cat "$1" > "$2"; }

is_ignored() {
  case "$1" in
    .DS_Store|Thumbs.db|desktop.ini|_SYNC-NOTICES.md|'~$'*|._*|*.tmp|*.conflict-*|*.local-edit-*) return 0 ;;
  esac
  return 1
}

office_locked() {  # Word/Excel keep ~$<name> (or ~$ + name minus 2 chars) beside an open file
  local dir="$1" name="$2"
  [ -e "$dir/~\$$name" ] && return 0
  [ ${#name} -gt 2 ] && [ -e "$dir/~\$${name:2}" ] && return 0
  return 1
}

purge_old() {
  local state="$1" cutoff
  cutoff=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d '30 days ago' +%Y-%m-%d)
  for d in "$state/trash"/*; do
    [ -d "$d" ] || continue
    [[ "$(basename "$d")" < "$cutoff" ]] && rm -rf "$d"
  done
  find "$state/tmp" -type f -mmin +60 -exec rm -f {} + 2>/dev/null
  find "$state/tmp" -mindepth 1 -maxdepth 1 -type d -mmin +60 -exec rm -rf {} + 2>/dev/null
  return 0
}

add_notice() {  # root folder level text
  local file="$1/$2/_SYNC-NOTICES.md"
  [ -d "$1/$2" ] || return 0
  if [ ! -f "$file" ]; then
    printf '# Sync notices\n\nRead these, act on them, then delete this file.\n\n' > "$file"
  fi
  grep -qF -- "$4" "$file" 2>/dev/null && return 0
  printf -- '- %s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M')" "$3" "$4" >> "$file"
}

# -- run ----------------------------------------------------------------------

sync_root() {  # root onlyfile trigger -> exit code
  local root="$1" only="$2" trigger="$3"
  local state="$root/.ca-sync" token rc
  load_device "$root" || { say "No sync set up in $root."; return 1; }
  token="$(root_token "$root")"
  if [ -z "$token" ]; then
    if [ -n "$OPT_SCAN" ]; then
      say "Scheduled runs aren't enabled for $root. On the computer, say 'reconnect sync' to Claude."
    else
      say "This computer isn't connected. Say 'reconnect sync' to Claude."
    fi
    return 3
  fi
  mkdir -p "$state/tmp" "$state/trash"
  lock_take "$root" || return 0
  install_runner "$root"
  rc=0
  sync_locked "$root" "$only" "$trigger" "$token" || rc=$?
  lock_release "$root"
  return $rc
}

sync_locked() {
  local root="$1" only="$2" trigger="$3" token="$4"
  local state="$root/.ca-sync" base="${BASE_URL%/}"
  # Working files live in the system temp folder, not the sync folder, so they can
  # be removed even when the run isn't allowed to delete files in the sync folder.
  local work; work="$(mktemp -d "${TMPDIR:-/tmp}/ca-sync.XXXXXX")"
  purge_old "$state"

  # Folders: what's on disk plus what the server named last time.
  local folders="$work/folders" scope_folder="" scope_path=""
  { find "$root" -mindepth 1 -maxdepth 1 -type d ! -name .ca-sync -exec basename {} \; ; cat "$state/folders" 2>/dev/null; } | sort -u > "$folders"

  if [ -n "$only" ]; then
    case "$only" in "$root"/*) ;; *) rm -rf "$work"; return 0 ;; esac
    local rel="${only#"$root"/}"
    scope_folder="${rel%%/*}"
    scope_path="${rel#*/}"
    if [ "$scope_folder" = "$rel" ] || [ "$scope_folder" = ".ca-sync" ]; then rm -rf "$work"; return 0; fi
    printf '%s\n' "$scope_folder" > "$folders"
  fi

  # Inventory: key<TAB>size<TAB>mtime<TAB>folder<TAB>rel for every candidate file.
  local list="$work/list" busy="$work/busy"
  : > "$list"; : > "$busy"
  while IFS= read -r folder; do
    [ -n "$folder" ] && [ -d "$root/$folder" ] || continue
    while IFS= read -r -d '' f; do
      local name="${f##*/}" relp="${f#"$root/$folder/"}"
      is_ignored "$name" && continue
      case "$relp" in .ca-sync/*|*$'\t'*|*$'\n'*) continue ;; esac
      if [ -n "$scope_path" ] && [ "$relp" != "$scope_path" ]; then continue; fi
      if office_locked "${f%/*}" "$name" || [ ! -r "$f" ]; then
        printf '%s\t%s\n' "$folder" "$relp" >> "$busy"; continue
      fi
      local sm; sm="$(file_stat "$f")" || continue
      printf '%s\t%s\t%s\t%s\t%s\n' "$folder/$relp" "${sm% *}" "${sm#* }" "$folder" "$relp" >> "$list"
    done < <(find "$root/$folder" -type f -print0 2>/dev/null)
  done < "$folders"

  # Hash only what changed since the cache (size + mtime).
  local cache="$state/hash-cache.tsv" joined="$work/joined"
  touch "$cache"
  # FILENAME, not NR==FNR: with an empty cache NR==FNR would match the list too.
  awk -F'\t' 'FILENAME == ARGV[1] { c[$1]=$2 FS $3 FS $4; next }
              { k=$1; split(c[k], v, FS); sha=(k in c && v[1]==$2 && v[2]==$3) ? v[3] : "-";
                print $0 FS sha }' "$cache" "$list" > "$joined"

  local body="$work/plan.json" newcache="$work/cache" first=1
  : > "$newcache"
  {
    # A scanned folder is mounted at a different path than on the computer, so
    # leave root_len out: the path-length check then uses the device's own platform only.
    printf '{"client_version":%s,"platform":%s,' "$(json_str "$CLIENT_VERSION")" \
      "$(json_str "$([ "$IS_MAC" = 1 ] && echo macos || echo linux)")"
    [ -z "$OPT_SCAN" ] && printf '"root_len":%s,' "${#root}"
    [ -n "$scope_folder" ] && printf '"scope":{"usecase_folder":%s,"paths":[%s]},' "$(json_str "$scope_folder")" "$(json_str "$scope_path")"
    [ -s "$state/pending-plan" ] && printf '"abandon_plan_id":%s,' "$(json_str "$(cat "$state/pending-plan")")"
    printf '"inventory":['
    while IFS=$'\t' read -r key size mtime folder relp sha; do
      if [ "$sha" = "-" ]; then sha="$(sha_of "$root/$key" 2>/dev/null)" || continue; fi
      [ -n "$sha" ] || continue
      printf '%s\t%s\t%s\t%s\n' "$key" "$size" "$mtime" "$sha" >> "$newcache"
      [ $first = 1 ] || printf ','
      first=0
      printf '{"usecase_folder":%s,"path":%s,"sha256":"%s","size":%s}' "$(json_str "$folder")" "$(json_str "$relp")" "$sha" "$size"
    done < "$joined"
    printf '],"busy":['
    first=1
    while IFS=$'\t' read -r folder relp; do
      [ $first = 1 ] || printf ','
      first=0
      printf '{"usecase_folder":%s,"path":%s}' "$(json_str "$folder")" "$(json_str "$relp")"
    done < "$busy"
    printf ']}'
  } > "$body"

  local plan="$work/plan.txt" code
  code="$(api POST "$base/api/sync/v4/plan?format=lines" "$body" "$plan" "$token")"
  if [ "$code" != "200" ]; then rm -rf "$work"; exit_for_status "$code"; return $?; fi
  [ -z "$only" ] && save_state "$newcache" "$cache"

  local plan_id=""
  tr '\t' "$US" < "$plan" > "$plan.us"
  : > "$work/folders.new"; : > "$work/actions"; : > "$work/notices"
  local held=0
  while IFS="$US" read -r kind a b c d e f g h; do
    case "$kind" in
      plan) plan_id="$a" ;;
      folder) [ "$b" = removed ] || { printf '%s\n' "$a" >> "$work/folders.new"; mkdir -p "$root/$a"; } ;;
      action) printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' "$a" "$US" "$b" "$US" "$c" "$US" "$d" "$US" "$e" "$US" "$f" "$US" "$g" "$US" "$h" "$US" "" >> "$work/actions" ;;
      notice) printf '%s%s%s%s%s\n' "$a" "$US" "$b" "$US" "$c" >> "$work/notices" ;;
      summary) case "$a" in *held_deletes=*) held="${a##*held_deletes=}"; held="${held%% *}" ;; esac ;;
    esac
  done < "$plan.us"
  [ -z "$only" ] && save_state "$work/folders.new" "$state/folders"
  if [ -s "$work/actions" ]; then printf '%s' "$plan_id" > "$state/pending-plan"; else remove_or_empty "$state/pending-plan"; fi

  local results="$work/results" n_pull=0 n_push=0 n_conf=0 n_del=0 n_skip=0 n_fail=0
  : > "$results"
  local op
  for op in conflict_pull local_edit_pull pull push trash_local delete_remote; do
    while IFS="$US" read -r n aop path sha keep url apiu hdr _; do
      [ "$aop" = "$op" ] || continue
      local target="$root/$path" status="done" got=""
      case "$op" in
        pull|conflict_pull|local_edit_pull)
          local tmp="$state/tmp/dl.$$.$n"
          if [ -z "$url" ] || ! curl -fsS -o "$tmp" "$url" 2>/dev/null; then
            auth_curl "$token" -o "$tmp" "$base$apiu" || status="failed"
          fi
          if [ "$status" = done ]; then
            got="$(sha_of "$tmp")"
            if [ "$got" != "$sha" ]; then status="failed"; rm -f "$tmp"; fi
          fi
          if [ "$status" = done ]; then
            [ -n "$keep" ] && [ -f "$target" ] && mv -f "$target" "$root/$keep"
            mkdir -p "$(dirname "$target")"
            if mv -f "$tmp" "$target"; then
              [ "$op" = pull ] && n_pull=$((n_pull + 1)) || n_conf=$((n_conf + 1))
            else status="skipped"; rm -f "$tmp"; fi
          fi ;;
        push)
          if [ -z "$url" ] || ! curl -fsS -T "$target" -H "x-amz-checksum-sha256: $hdr" "$url" >/dev/null 2>&1; then
            auth_curl "$token" -T "$target" "$base$apiu" || status="failed"
          fi
          [ "$status" = done ] && n_push=$((n_push + 1)) ;;
        trash_local)
          if [ -f "$target" ]; then
            local dest="$state/trash/$(date +%Y-%m-%d)/$path"
            mkdir -p "$(dirname "$dest")"
            [ -e "$dest" ] && dest="$dest.$$"
            mv -f "$target" "$dest" || status="failed"
          fi
          [ "$status" = done ] && n_del=$((n_del + 1)) ;;
        delete_remote) n_del=$((n_del + 1)) ;;
      esac
      [ "$status" = skipped ] && n_skip=$((n_skip + 1))
      [ "$status" = failed ] && n_fail=$((n_fail + 1))
      [ -s "$results" ] && printf ',' >> "$results"
      printf '{"path":%s,"op":"%s","status":"%s"%s}' "$(json_str "$path")" "$op" "$status" \
        "$([ -n "$got" ] && printf ',"sha256":"%s"' "$got")" >> "$results"
    done < "$work/actions"
  done

  if [ -s "$results" ]; then
    printf '{"plan_id":"%s","results":[%s]}' "$plan_id" "$(cat "$results")" > "$work/commit.json"
    code="$(api POST "$base/api/sync/v4/commit?format=lines" "$work/commit.json" "$work/commit.txt" "$token")"
    if [ "$code" != "200" ]; then
      printf '%s COMMIT-FAILED device=%s status=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DEVICE_NAME" "$code" >> "$state/sync.log"
      rm -rf "$work"; exit_for_status "$code"; return $?
    fi
    remove_or_empty "$state/pending-plan"
    tr '\t' "$US" < "$work/commit.txt" | while IFS="$US" read -r kind a b c; do
      [ "$kind" = notice ] && printf '%s%s%s%s%s\n' "$a" "$US" "$b" "$US" "$c" >> "$work/notices"
      [ "$kind" = result ] && [ "$b" = conflict ] && printf 'x\n' >> "$work/conflicts"
    done
    [ -f "$work/conflicts" ] && n_conf=$((n_conf + $(wc -l < "$work/conflicts")))
  fi

  local n_notices=0 n_warn=0
  while IFS="$US" read -r folder level text; do
    [ -n "$text" ] || continue
    add_notice "$root" "$folder" "$level" "$text"
    n_notices=$((n_notices + 1))
    [ "$level" != info ] && n_warn=$((n_warn + 1))
  done < "$work/notices"

  local nfold; nfold=$(grep -c "^folder$US" "$plan.us" 2>/dev/null || true)
  local line="OK device=${DEVICE_NAME// /-} trigger=$trigger folders=${nfold:-0} pull=$n_pull push=$n_push conflicts=$n_conf deletes=$n_del held_deletes=$held skipped=$n_skip failed=$n_fail notices=$n_notices"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >> "$state/sync.log"
  if [ "$QUIET" != 1 ] || [ "$n_warn" -gt 0 ] || [ "$n_fail" -gt 0 ]; then printf '%s\n' "$line"; fi
  rm -rf "$work"
  if [ "$n_warn" -gt 0 ] || [ "${held:-0}" -gt 0 ]; then return 2; fi
  return 0
}

sync_all() {  # onlyfile trigger
  local only="$1" trigger="$2" worst=0 rc root
  if [ -z "$(roots)" ]; then
    [ -n "$only" ] && return 0
    say "Context Accelerator sync isn't set up on this computer yet. Say 'set up Context Accelerator sync' to Claude."
    return 1
  fi
  while IFS= read -r root; do
    if [ ! -d "$root" ]; then
      [ -z "$only" ] && { say "Sync folder $root is missing. Was it moved? Run setup again with the new location."; [ $worst -lt 2 ] && worst=2; }
      continue
    fi
    if [ -n "$only" ]; then case "$only" in "$root"/*) ;; *) continue ;; esac; fi
    rc=0
    sync_root "$root" "$only" "$trigger" || rc=$?
    [ $rc -gt $worst ] && worst=$rc
  done < <(roots)
  return $worst
}

# -- setup / status ---------------------------------------------------------------

do_setup() {  # reset?
  local reset="$1" root="$OPT_ROOT" base="$OPT_BASE"
  [ -n "$OPT_CLAIM" ] || { echo "Missing --claim <code>"; return 1; }
  [ -z "$root" ] && [ "$reset" = 1 ] && root="$(roots | head -n 1)"
  [ -n "$root" ] || { echo "Missing --root <folder>"; return 1; }
  mkdir -p "$root/.ca-sync/tmp" "$root/.ca-sync/trash"
  root="$(cd "$root" && pwd)"  # logical path: hooks report paths as the user sees them
  local old_id=""
  if load_device "$root"; then old_id="$DEVICE_ID"; [ -z "$base" ] && base="$BASE_URL"; fi
  [ -n "$base" ] || { echo "Missing --base <url>"; return 1; }
  base="${base%/}"
  local body out code
  body="$(mktemp)"; out="$(mktemp)"
  printf '{"code":%s,"platform":"macos","client_version":"%s"}' "$(json_str "$OPT_CLAIM")" "$CLIENT_VERSION" > "$body"
  [ "$IS_MAC" = 1 ] || sed -i.bak 's/"macos"/null/' "$body"
  code="$(api POST "$base/api/sync/v4/devices/claim?format=lines" "$body" "$out" "")"
  rm -f "$body" "$body.bak"
  if [ "$code" != 200 ]; then
    echo "Setup failed (HTTP $code). The code may have expired: ask Claude for a new one."
    rm -f "$out"; [ "$code" = 000 ] && return 4; return 3
  fi
  local k v token=""
  DEVICE_ID="" DEVICE_NAME="" COMPANY_ID="" COMPANY_NAME=""
  while IFS=$'\t' read -r k v; do
    case "$k" in
      device_id) DEVICE_ID="$v" ;; device_name) DEVICE_NAME="$v" ;;
      company_id) COMPANY_ID="$v" ;; company_name) COMPANY_NAME="$v" ;;
      device_token) token="$v" ;;
    esac
  done < "$out"
  rm -f "$out"
  [ -n "$token" ] || { echo "Setup failed: no token in the reply"; return 1; }
  BASE_URL="$base"
  token_save "$DEVICE_ID" "$token" || { echo "Couldn't store the token in the Keychain"; return 1; }
  save_device "$root"
  [ "$old_id" = "$DEVICE_ID" ] || rm -f "$root/.ca-sync/folders" "$root/.ca-sync/hash-cache.tsv"
  add_root "$root"
  echo "OK setup device=$DEVICE_NAME company=$COMPANY_NAME root=$root"
  enable_scheduled "$root" || echo "Scheduled runs not enabled; run enable-scheduled later."
  return 0
}

enable_scheduled() {  # root
  local root="$1" body out code k v tok=""
  load_device "$root" || { echo "No sync set up in $root."; return 1; }
  body="$(mktemp)"; out="$(mktemp)"; printf '{}' > "$body"
  code="$(api POST "${BASE_URL%/}/api/sync/v4/devices/scheduled-token?format=lines" "$body" "$out" "$(token_read "$DEVICE_ID")")"
  rm -f "$body"
  if [ "$code" != 200 ]; then rm -f "$out"; QUIET=0 exit_for_status "$code"; return $?; fi
  while IFS=$'\t' read -r k v; do [ "$k" = scheduled_token ] && tok="$v"; done < "$out"
  rm -f "$out"
  [ -n "$tok" ] || { echo "No scheduled token in the reply"; return 1; }
  install_runner "$root"
  ( umask 077; printf '%s' "$tok" > "$root/.ca-sync/scheduled-token" )
  echo "OK scheduled runs enabled for $root"
}

disable_scheduled() {  # root
  local root="$1" body out code
  load_device "$root" || return 0
  body="$(mktemp)"; out="$(mktemp)"; printf '{}' > "$body"
  code="$(api DELETE "${BASE_URL%/}/api/sync/v4/devices/scheduled-token" "$body" "$out" "$(token_read "$DEVICE_ID")")"
  rm -f "$body" "$out"
  [ "$code" = 200 ] || { QUIET=0 exit_for_status "$code"; return $?; }
  rm -f "$root/.ca-sync/scheduled-token"
  echo "OK scheduled runs disabled for $root"
}

for_roots() {  # command: run it for --root, or every root
  local worst=0 rc root
  if [ -n "$OPT_ROOT" ]; then
    "$1" "$(cd "$OPT_ROOT" && pwd)"; return $?
  fi
  [ -n "$(roots)" ] || { echo "Sync isn't set up on this computer."; return 1; }
  while IFS= read -r root; do
    rc=0; "$1" "$root" || rc=$?
    [ $rc -gt $worst ] && worst=$rc
  done < <(roots)
  return $worst
}

do_status() {
  local root
  [ -n "$(roots)" ] || { echo "Sync isn't set up on this computer."; return 1; }
  while IFS= read -r root; do
    echo "Folder:  $root"
    if load_device "$root"; then
      echo "Device:  $DEVICE_NAME ($DEVICE_ID)"
      echo "Company: $COMPANY_NAME ($COMPANY_ID)"
      echo "Server:  $BASE_URL"
      if [ -n "$(root_token "$root")" ]; then echo "Token:   stored"; else echo "Token:   missing - reconnect sync"; fi
      if [ -f "$root/.ca-sync/scheduled-token" ]; then echo "Scheduled runs: enabled"
      else echo "Scheduled runs: not enabled - run enable-scheduled"; fi
    fi
    [ -f "$root/.ca-sync/sync.log" ] && echo "Last:    $(tail -n 1 "$root/.ca-sync/sync.log")"
    echo "Notices: $(find "$root" -name _SYNC-NOTICES.md -type f 2>/dev/null | wc -l | tr -d ' ') folder(s) with _SYNC-NOTICES.md"
    echo "Log:     $root/.ca-sync/sync.log"
    echo
  done < <(roots)
}

do_restore_held() {
  local root body out code worst=0
  while IFS= read -r root; do
    load_device "$root" || continue
    body="$(mktemp)"; out="$(mktemp)"; printf '{}' > "$body"
    code="$(api POST "${BASE_URL%/}/api/sync/v4/restore-held-deletes" "$body" "$out" "$(token_read "$DEVICE_ID")")"
    rm -f "$body" "$out"
    if [ "$code" = 200 ]; then echo "Held deletes in $root will be restored on the next sync."
    else exit_for_status "$code"; rc=$?; [ $rc -gt $worst ] && worst=$rc; fi
  done < <(roots)
  [ $worst = 0 ] || return $worst
  sync_all "" restore
}

hook_path() {  # file_path from a Claude Code hook's JSON on stdin
  local raw
  raw="$(cat)"
  printf '%s' "$raw" | tr -d '\n' | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

# -- main ---------------------------------------------------------------------

case "$CMD" in
  setup) do_setup 0; exit $? ;;
  reset-token) do_setup 1; exit $? ;;
  status) do_status; exit $? ;;
  restore-held) do_restore_held; exit $? ;;
  enable-scheduled) for_roots enable_scheduled; exit $? ;;
  disable-scheduled) for_roots disable_scheduled; exit $? ;;
  run) sync_all "$OPT_PATH" "$OPT_TRIGGER"; exit $? ;;
  hook)
    QUIET=1
    if [ "$REST" = post-edit ]; then
      p="$(hook_path)"
      [ -n "$p" ] && sync_all "$p" post_edit
    else
      sync_all "" session_start
    fi
    exit 0 ;;  # hooks never block Claude; problems surface on the scheduled run
  *) echo "Usage: ca-sync.sh setup|run|hook|status|reset-token|restore-held|enable-scheduled|disable-scheduled"; exit 1 ;;
esac
