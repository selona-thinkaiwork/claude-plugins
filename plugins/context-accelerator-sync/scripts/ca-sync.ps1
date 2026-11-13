# Context Accelerator Sync v4 client for Windows PowerShell 5.1.
#
# Deliberately simple: it hashes files, asks the server for a plan, carries the
# plan out (downloads, uploads, renames, moves to trash) and reports back. Every
# sync decision is made on the server. File bytes go straight to and from S3,
# with the API as a fallback where *.amazonaws.com is blocked.
#
#   ca-sync.ps1 setup --claim <code> --root <folder> --base <url>
#   ca-sync.ps1 run [--quiet] [--path <file>] [--trigger <name>]
#   ca-sync.ps1 hook post-edit | session-start      (reads the hook JSON from stdin)
#   ca-sync.ps1 status
#   ca-sync.ps1 restore-held                          (undo deletes held by the safety limit)
#   ca-sync.ps1 reset-token --claim <code> [--root <folder>]
#   ca-sync.ps1 enable-scheduled | disable-scheduled  (Claude scheduled tasks; setup enables it)
#
# Claude's scheduled tasks run in a Linux VM that can't read DPAPI. For them,
# each sync folder gets a copy of these scripts in .ca-sync\bin and a separate
# scheduled-run token in .ca-sync\scheduled-token. The VM runs ca-sync.sh with
# --scan and syncs as the same device; the shared lock keeps runs apart.
#
# Exit codes: 0 OK, 2 OK but something needs a human, 3 device disconnected,
# 4 server unreachable or sync turned off, 5 plugin too old, 1 usage/local error.
#
# The device token is stored with DPAPI (CurrentUser) and never printed.
# Source is ASCII only: Windows PowerShell 5.1 reads BOM-less files as ANSI.

$ErrorActionPreference = 'Stop'
$ClientVersion = '4.1.1'
$Script:ExitCode = 0

# -- Arguments ----------------------------------------------------------------

$Command = if ($args.Count -gt 0) { [string]$args[0] } else { 'run' }
$Opt = @{}
$Rest = @()
for ($i = 1; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -match '^--?([A-Za-z-]+)$') {
        $name = $Matches[1].ToLower()
        if ($name -in @('quiet')) { $Opt[$name] = $true; continue }
        if ($i + 1 -lt $args.Count) { $Opt[$name] = [string]$args[$i + 1]; $i++ } else { $Opt[$name] = $true }
    } else { $Rest += $a }
}
$Quiet = [bool]$Opt['quiet']

# -- .NET plumbing ------------------------------------------------------------

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Web.Extensions
Add-Type -AssemblyName System.Security
try { [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials } catch { }

$Json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$Json.MaxJsonLength = [int]::MaxValue
$Json.RecursionLimit = 100
$Utf8 = New-Object System.Text.UTF8Encoding($false)

$Handler = New-Object System.Net.Http.HttpClientHandler
$Handler.UseProxy = $true
$Handler.AllowAutoRedirect = $true
$Http = New-Object System.Net.Http.HttpClient($Handler)
$Http.Timeout = [TimeSpan]::FromMinutes(30)
$Http.DefaultRequestHeaders.UserAgent.ParseAdd("ContextAcceleratorSync/$ClientVersion")

$AppDir = Join-Path $env:APPDATA 'ContextAcceleratorSync'
$ConfigFile = Join-Path $AppDir 'config.json'

# Messages go straight to the console: Out-Line inside a function would
# become part of its return value and corrupt the exit code.
function Out-Line([string]$text) { [Console]::Out.WriteLine($text) }
function Say([string]$text) { if (-not $Quiet) { Out-Line $text } }

function ConvertTo-JsonText($o) {
    # Written by hand: JavaScriptSerializer chokes on the PSObject wrappers that
    # PowerShell puts around values returned from functions and pipelines.
    # Non-ASCII is escaped as \uXXXX, so the request body is plain ASCII.
    if ($null -eq $o) { return 'null' }
    $o = $o.psobject.BaseObject
    if ($o -is [bool]) { if ($o) { return 'true' } else { return 'false' } }
    if ($o -is [string] -or $o -is [char] -or $o -is [guid]) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append([char]34)
        foreach ($ch in ([string]$o).ToCharArray()) {
            $n = [int]$ch
            if ($n -eq 34) { [void]$sb.Append([char]92).Append([char]34) }
            elseif ($n -eq 92) { [void]$sb.Append([char]92).Append([char]92) }
            elseif ($n -lt 32 -or $n -gt 126) { [void]$sb.Append([char]92).Append('u').Append($n.ToString('x4')) }
            else { [void]$sb.Append($ch) }
        }
        [void]$sb.Append([char]34)
        return $sb.ToString()
    }
    if ($o -is [ValueType]) { return ([IFormattable]$o).ToString($null, [Globalization.CultureInfo]::InvariantCulture) }
    if ($o -is [Collections.IDictionary]) {
        $parts = foreach ($k in @($o.Keys)) { (ConvertTo-JsonText ([string]$k)) + ':' + (ConvertTo-JsonText $o[$k]) }
        return '{' + (@($parts) -join ',') + '}'
    }
    if ($o -is [Collections.IEnumerable]) {
        $parts = foreach ($i in $o) { ConvertTo-JsonText $i }
        return '[' + (@($parts) -join ',') + ']'
    }
    return ConvertTo-JsonText ([string]$o)
}

function Read-JsonFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $text = [IO.File]::ReadAllText($path, $Utf8)
    if (-not $text.Trim()) { return $null }
    return $Json.DeserializeObject($text)
}

function Write-JsonFile([string]$path, $obj) {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-JsonText $obj), $Utf8)
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
}

function Get-Sha256([string]$path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { return (-join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') })) }
    finally { $fs.Dispose(); $sha.Dispose() }
}

class SyncHttpError : Exception {
    [int]$Status
    SyncHttpError([int]$status, [string]$message) : base($message) { $this.Status = $status }
}

function Invoke-Api([string]$method, [string]$url, $body, [string]$token) {
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::new($method), $url)
    if ($token) { $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $token) }
    if ($null -ne $body) {
        $req.Content = New-Object System.Net.Http.StringContent((ConvertTo-JsonText $body), $Utf8, 'application/json')
    }
    try { $resp = $Http.SendAsync($req).GetAwaiter().GetResult() }
    catch { throw [SyncHttpError]::new(0, "Can't reach $url ($($_.Exception.GetBaseException().Message))") }
    # Decode as UTF-8 explicitly: 5.1 would otherwise guess Latin-1 and mangle names.
    $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $text = $Utf8.GetString($bytes)
    if (-not $resp.IsSuccessStatusCode) {
        $msg = $text
        try { $e = $Json.DeserializeObject($text); if ($e['error']) { $msg = $e['error']['message'] } } catch { }
        throw [SyncHttpError]::new([int]$resp.StatusCode, $msg)
    }
    if (-not $text) { return $null }
    return $Json.DeserializeObject($text)
}

function Exit-ForHttp([SyncHttpError]$e) {
    switch ($e.Status) {
        0 { Say "Sync couldn't reach the server: $($e.Message)"; return 4 }
        401 { Say "This computer was disconnected from Context Accelerator sync. Say 'reconnect sync' to Claude."; return 3 }
        403 { Say "Sync isn't allowed: $($e.Message)"; return 3 }
        409 { return 0 }  # another sync for this device is already running
        426 { Say $e.Message; return 5 }
        503 { Say "Sync is turned off on the server right now. Nothing was changed."; return 4 }
        default { Say "Server error $($e.Status): $($e.Message)"; return 4 }
    }
}

# -- Token (DPAPI, CurrentUser) ------------------------------------------------

function Get-TokenPath([string]$deviceId) { Join-Path $AppDir "devices\$deviceId.token" }

function Save-Token([string]$deviceId, [string]$token) {
    $p = Get-TokenPath $deviceId
    New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force | Out-Null
    $enc = [Security.Cryptography.ProtectedData]::Protect($Utf8.GetBytes($token), $null, 'CurrentUser')
    [IO.File]::WriteAllBytes($p, $enc)
}

function Read-Token([string]$deviceId) {
    $p = Get-TokenPath $deviceId
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $dec = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($p), $null, 'CurrentUser')
    return $Utf8.GetString($dec)
}

# -- Roots ---------------------------------------------------------------------

function Get-Roots {
    $cfg = Read-JsonFile $ConfigFile
    if ($null -eq $cfg -or $null -eq $cfg['roots']) { return @() }
    return @($cfg['roots'])
}

function Add-Root([string]$root) {
    $roots = @(Get-Roots | Where-Object { $_ -ne $root }) + $root
    Write-JsonFile $ConfigFile @{ roots = $roots }
}

function Get-StateDir([string]$root) { Join-Path $root '.ca-sync' }

function Initialize-StateDir([string]$root) {
    $d = Get-StateDir $root
    foreach ($sub in @('', 'tmp', 'trash')) {
        $p = if ($sub) { Join-Path $d $sub } else { $d }
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
    try { (Get-Item -LiteralPath $d -Force).Attributes = 'Directory, Hidden' } catch { }
}

# -- Lock ------------------------------------------------------------------------

function Enter-Lock([string]$root) {
    $lock = Join-Path (Get-StateDir $root) 'lock'
    for ($try = 0; $try -lt 2; $try++) {
        try {
            $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $b = $Utf8.GetBytes((ConvertTo-JsonText @{ pid = $PID; host = $env:COMPUTERNAME; started_at = (Get-Date).ToUniversalTime().ToString('o') }))
            $fs.Write($b, 0, $b.Length); $fs.Dispose()
            return $true
        } catch [IO.IOException] {
            $info = $null
            try { $info = Read-JsonFile $lock } catch { }
            $stale = $true
            if ($info) {
                $age = (Get-Date).ToUniversalTime() - [DateTime]::Parse($info['started_at']).ToUniversalTime()
                $here = (-not $info['host']) -or ($info['host'] -eq $env:COMPUTERNAME)
                # A lock from another machine (the scheduled-task VM) can only be judged by age.
                $alive = (-not $here) -or ($null -ne (Get-Process -Id ([int]$info['pid']) -ErrorAction SilentlyContinue))
                $stale = (-not $alive) -or ($age.TotalMinutes -gt 10)
            } else {
                $stale = ((Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime).TotalMinutes -gt 10
            }
            if (-not $stale) { return $false }
            Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
        }
    }
    return $false
}

function Exit-Lock([string]$root) {
    Remove-Item -LiteralPath (Join-Path (Get-StateDir $root) 'lock') -Force -ErrorAction SilentlyContinue
}

# -- Inventory --------------------------------------------------------------------

$IgnoreNames = @('.DS_Store', 'Thumbs.db', 'desktop.ini', '_SYNC-NOTICES.md')
$IgnoreLike = @('~$*', '._*', '*.tmp', '*.conflict-*', '*.local-edit-*')

function Test-Ignored([string]$name) {
    if ($IgnoreNames -contains $name) { return $true }
    foreach ($p in $IgnoreLike) { if ($name -like $p) { return $true } }
    return $false
}

function Test-OfficeLock([IO.FileInfo]$f) {
    # Word/Excel keep "~$" + name (or + name minus its first two characters) open.
    $dir = $f.DirectoryName
    $n = $f.Name
    $candidates = @("~`$$n")
    if ($n.Length -gt 2) { $candidates += "~`$$($n.Substring(2))" }
    foreach ($c in $candidates) { if ([IO.File]::Exists((Join-Path $dir $c))) { return $true } }
    return $false
}

function Get-Inventory([string]$root, [string[]]$folders, $cache, [string]$onlyFull) {
    $inv = New-Object System.Collections.ArrayList
    $busy = New-Object System.Collections.ArrayList
    $newCache = @{}
    $rootLen = $root.TrimEnd('\').Length + 1
    foreach ($folder in $folders) {
        $base = Join-Path $root $folder
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $files = if ($onlyFull) {
            if ($onlyFull.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $onlyFull -PathType Leaf)) {
                @(Get-Item -LiteralPath $onlyFull -Force)
            } else { @() }
        } else { Get-ChildItem -LiteralPath $base -Recurse -File -Force -ErrorAction SilentlyContinue }
        foreach ($f in $files) {
            if (Test-Ignored $f.Name) { continue }
            $rel = $f.FullName.Substring($base.Length + 1).Replace('\', '/')
            if ($rel -like '.ca-sync/*') { continue }
            $key = $f.FullName.Substring($rootLen).Replace('\', '/')
            if (Test-OfficeLock $f) { [void]$busy.Add(@{ usecase_folder = $folder; path = $rel }); continue }
            $mtime = $f.LastWriteTimeUtc.Ticks
            $hit = if ($cache) { $cache[$key] } else { $null }
            $sha = $null
            if ($hit -and [long]$hit[0] -eq $f.Length -and [long]$hit[1] -eq $mtime) { $sha = [string]$hit[2] }
            else {
                try { $sha = Get-Sha256 $f.FullName }
                catch { [void]$busy.Add(@{ usecase_folder = $folder; path = $rel }); continue }
            }
            $newCache[$key] = @($f.Length, $mtime, $sha)
            [void]$inv.Add(@{ usecase_folder = $folder; path = $rel; sha256 = $sha; size = $f.Length })
        }
    }
    return @{ inventory = $inv; busy = $busy; cache = $newCache }
}

# -- Transfers ----------------------------------------------------------------

function Get-Remote([string]$url, [string]$token, [string]$dest) {
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $url)
    if ($token) { $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $token) }
    $resp = $Http.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) { throw "HTTP $([int]$resp.StatusCode)" }
    $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $out = [IO.File]::Create($dest)
    try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
}

function Receive-File($a, [string]$base, [string]$token, [string]$tmpDir) {
    $tmp = Join-Path $tmpDir ([guid]::NewGuid().ToString('N'))
    $got = $false
    if ($a['url']) { try { Get-Remote $a['url'] $null $tmp; $got = $true } catch { } }
    if (-not $got) { Get-Remote ($base + $a['api_url']) $token $tmp }
    $sha = Get-Sha256 $tmp
    if ($sha -ne $a['sha256']) { Remove-Item -LiteralPath $tmp -Force; throw "checksum mismatch" }
    return @{ tmp = $tmp; sha = $sha }
}

function Send-File([string]$url, [string]$token, $headers, [string]$path) {
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Put, $url)
        if ($token) { $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $token) }
        $req.Content = New-Object System.Net.Http.StreamContent($fs)
        $req.Content.Headers.ContentLength = $fs.Length
        if ($headers) { foreach ($k in $headers.Keys) { [void]$req.Headers.TryAddWithoutValidation($k, [string]$headers[$k]) } }
        $resp = $Http.SendAsync($req).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) { throw "HTTP $([int]$resp.StatusCode)" }
    } finally { $fs.Dispose() }
}

function Move-Into([string]$tmp, [string]$target) {
    $dir = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ([IO.File]::Exists($target)) { [IO.File]::Replace($tmp, $target, [NullString]::Value) } else { [IO.File]::Move($tmp, $target) }
}

function Get-LocalPath([string]$root, [string]$rel) { Join-Path $root ($rel.Replace('/', '\')) }

# -- Notices and log ----------------------------------------------------------

function Add-Notices([string]$root, $notices) {
    $byFolder = @{}
    foreach ($n in $notices) {
        $f = [string]$n['folder']
        if (-not $byFolder.ContainsKey($f)) { $byFolder[$f] = New-Object System.Collections.ArrayList }
        [void]$byFolder[$f].Add($n)
    }
    foreach ($folder in $byFolder.Keys) {
        $dir = Join-Path $root $folder
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $file = Join-Path $dir '_SYNC-NOTICES.md'
        $existing = if (Test-Path -LiteralPath $file) { [IO.File]::ReadAllText($file, $Utf8) } else { "# Sync notices`r`n`r`nRead these, act on them, then delete this file.`r`n`r`n" }
        $add = ''
        foreach ($n in $byFolder[$folder]) {
            if ($existing.Contains([string]$n['text'])) { continue }
            $add += "- $((Get-Date).ToString('yyyy-MM-dd HH:mm')) [$($n['level'])] $($n['text'])`r`n"
        }
        if ($add) { [IO.File]::WriteAllText($file, $existing + $add, $Utf8) }
    }
}

function Write-Log([string]$root, [string]$line) {
    $log = Join-Path (Get-StateDir $root) 'sync.log'
    [IO.File]::AppendAllText($log, "$((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")) $line`r`n", $Utf8)
    $fi = Get-Item -LiteralPath $log
    if ($fi.Length -gt 2MB) {
        $lines = [IO.File]::ReadAllLines($log, $Utf8)
        [IO.File]::WriteAllLines($log, $lines[($lines.Length - 2000)..($lines.Length - 1)], $Utf8)
    }
}

function Clear-OldTrash([string]$root) {
    $trash = Join-Path (Get-StateDir $root) 'trash'
    $cut = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd')
    Get-ChildItem -LiteralPath $trash -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -lt $cut } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    Get-ChildItem -LiteralPath (Join-Path (Get-StateDir $root) 'tmp') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

# -- Scheduled runs (Claude scheduled tasks in a Linux VM) -----------------------

$RunnerFiles = @('ca-sync', 'ca-sync.sh', 'ca-sync.ps1', 'ca-sync.cmd', 'server-url')

function Install-RunnerFiles([string]$root) {
    # Keeps .ca-sync\bin at this plugin version, so connecting the sync folder is enough.
    $bin = Join-Path (Get-StateDir $root) 'bin'
    if ([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -eq [IO.Path]::GetFullPath($bin).TrimEnd('\')) { return }
    $versionFile = Join-Path $bin 'VERSION'
    if ((Test-Path -LiteralPath $versionFile) -and ([IO.File]::ReadAllText($versionFile).Trim() -eq $ClientVersion)) { return }
    try {
        if (-not (Test-Path -LiteralPath $bin)) { New-Item -ItemType Directory -Path $bin -Force | Out-Null }
        foreach ($f in $RunnerFiles) {
            $src = Join-Path $PSScriptRoot $f
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $bin $f) -Force }
        }
        [IO.File]::WriteAllText($versionFile, $ClientVersion)
    } catch { }
}

function Enable-Scheduled([string]$root) {
    $d = Read-JsonFile (Join-Path (Get-StateDir $root) 'device.json')
    if (-not $d) { Out-Line "No sync set up in $root."; return 1 }
    $token = Read-Token $d['device_id']
    if (-not $token) { Out-Line "This computer isn't connected. Say 'reconnect sync' to Claude."; return 3 }
    try {
        $r = Invoke-Api 'POST' "$(([string]$d['base_url']).TrimEnd('/'))/api/sync/v4/devices/scheduled-token" $null $token
    } catch [SyncHttpError] { return (Exit-ForHttp $_.Exception) }
    Install-RunnerFiles $root
    [IO.File]::WriteAllText((Join-Path (Get-StateDir $root) 'scheduled-token'), [string]$r['scheduled_token'])
    Out-Line "OK scheduled runs enabled for $root"
    return 0
}

function Disable-Scheduled([string]$root) {
    $d = Read-JsonFile (Join-Path (Get-StateDir $root) 'device.json')
    if (-not $d) { return 0 }
    $file = Join-Path (Get-StateDir $root) 'scheduled-token'
    try {
        [void](Invoke-Api 'DELETE' "$(([string]$d['base_url']).TrimEnd('/'))/api/sync/v4/devices/scheduled-token" $null (Read-Token $d['device_id']))
    } catch [SyncHttpError] { return (Exit-ForHttp $_.Exception) }
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    Out-Line "OK scheduled runs disabled for $root"
    return 0
}

function Invoke-ForRoots([scriptblock]$action) {
    $roots = @(Get-Roots)
    if ([string]$Opt['root']) { $roots = @([IO.Path]::GetFullPath([string]$Opt['root']).TrimEnd('\')) }
    if ($roots.Count -eq 0) { Out-Line "Sync isn't set up on this computer."; return 1 }
    $worst = 0
    foreach ($root in $roots) { $c = & $action $root; if ($c -gt $worst) { $worst = $c } }
    return $worst
}

# -- run ----------------------------------------------------------------------

function Invoke-Sync([string]$root, [string]$onlyFile, [string]$trigger) {
    $state = Get-StateDir $root
    $device = Read-JsonFile (Join-Path $state 'device.json')
    if ($null -eq $device) { Say "No sync set up in $root."; return 1 }
    $token = Read-Token $device['device_id']
    if (-not $token) { Say "This computer isn't connected. Say 'reconnect sync' to Claude."; return 3 }
    $base = ([string]$device['base_url']).TrimEnd('/')
    if (-not (Enter-Lock $root)) { return 0 }
    Install-RunnerFiles $root
    try {
        Clear-OldTrash $root
        $cacheFile = Join-Path $state 'hash-cache.json'
        $cache = $null
        try { $cache = Read-JsonFile $cacheFile } catch { }
        $folders = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.ca-sync' } | ForEach-Object { $_.Name })
        $known = @($device['folders'])
        $folders = @($folders + $known | Where-Object { $_ } | Select-Object -Unique)

        $scope = $null
        if ($onlyFile) {
            $full = [IO.Path]::GetFullPath($onlyFile)
            $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\')
            if (-not $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) { return 0 }
            $relAll = $full.Substring($rootFull.Length + 1)
            $parts = $relAll.Split([char[]]@('\'), 2)
            if ($parts.Count -lt 2 -or $parts[0] -eq '.ca-sync') { return 0 }
            $scope = @{ usecase_folder = $parts[0]; paths = @($parts[1].Replace('\', '/')) }
            $folders = @($parts[0])
        }

        $inv = Get-Inventory $root $folders $cache $(if ($onlyFile) { [IO.Path]::GetFullPath($onlyFile) } else { $null })
        $body = @{
            client_version = $ClientVersion; platform = 'windows'; root_len = $root.TrimEnd('\').Length
            inventory = $inv.inventory; busy = $inv.busy
        }
        if ($scope) { $body['scope'] = $scope }
        # A run that died between plan and commit leaves its plan open; we hold
        # the lock, so tell the server to drop it instead of waiting for expiry.
        $pendingFile = Join-Path $state 'pending-plan'
        if (Test-Path -LiteralPath $pendingFile) { $body['abandon_plan_id'] = ([IO.File]::ReadAllText($pendingFile)).Trim() }
        try { $plan = Invoke-Api 'POST' "$base/api/sync/v4/plan" $body $token }
        catch [SyncHttpError] { return (Exit-ForHttp $_.Exception) }
        if (@($plan['actions']).Count -gt 0) { [IO.File]::WriteAllText($pendingFile, [string]$plan['plan_id']) }
        else { Remove-Item -LiteralPath $pendingFile -Force -ErrorAction SilentlyContinue }

        if (-not $onlyFile) {
            # Only a full inventory may replace the cache.
            try { Write-JsonFile $cacheFile $inv.cache } catch { }
            $device['folders'] = @($plan['folders'] | Where-Object { $_['status'] -ne 'removed' } | ForEach-Object { $_['folder'] })
            Write-JsonFile (Join-Path $state 'device.json') $device
        }
        foreach ($f in $plan['folders']) {
            if ($f['status'] -eq 'removed') { continue }
            $p = Join-Path $root $f['folder']
            if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
        }

        $results = New-Object System.Collections.ArrayList
        $tmpDir = Join-Path $state 'tmp'
        $count = @{ pull = 0; push = 0; conflicts = 0; deletes = 0; skipped = 0; failed = 0 }
        $actions = @($plan['actions'])
        $order = @('conflict_pull', 'local_edit_pull', 'pull', 'push', 'trash_local', 'delete_remote')
        foreach ($op in $order) {
            foreach ($a in ($actions | Where-Object { $_['op'] -eq $op })) {
                $rel = [string]$a['path']
                $target = Get-LocalPath $root $rel
                $r = @{ path = $rel; op = $op; status = 'done' }
                try {
                    switch ($op) {
                        { $_ -in @('pull', 'conflict_pull', 'local_edit_pull') } {
                            $got = Receive-File $a $base $token $tmpDir
                            if ($a['keep_local_as'] -and [IO.File]::Exists($target)) {
                                $side = Get-LocalPath $root $a['keep_local_as']
                                [IO.File]::Move($target, $side)
                            }
                            try { Move-Into $got.tmp $target }
                            catch { Remove-Item -LiteralPath $got.tmp -Force -ErrorAction SilentlyContinue; $r.status = 'skipped'; $r.error = 'file is in use' }
                            if ($r.status -eq 'done') {
                                $r.sha256 = $got.sha
                                if ($op -eq 'pull') { $count.pull++ } else { $count.conflicts++ }
                            }
                        }
                        'push' {
                            $sent = $false
                            if ($a['upload_url']) { try { Send-File $a['upload_url'] $null $a['headers'] $target; $sent = $true } catch { } }
                            if (-not $sent) { Send-File ($base + $a['api_upload_url']) $token $null $target }
                            $count.push++
                        }
                        'trash_local' {
                            if ([IO.File]::Exists($target)) {
                                $dest = Join-Path (Join-Path (Join-Path $state 'trash') (Get-Date).ToString('yyyy-MM-dd')) ($rel.Replace('/', '\'))
                                $dd = Split-Path -Parent $dest
                                if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
                                if ([IO.File]::Exists($dest)) { $dest = "$dest.$([guid]::NewGuid().ToString('N').Substring(0, 6))" }
                                [IO.File]::Move($target, $dest)
                            }
                            $count.deletes++
                        }
                        'delete_remote' { $count.deletes++ }
                    }
                } catch {
                    $r.status = 'failed'
                    $r.error = $_.Exception.GetBaseException().Message
                }
                if ($r.status -eq 'skipped') { $count.skipped++ }
                if ($r.status -eq 'failed') { $count.failed++ }
                [void]$results.Add($r)
            }
        }

        $notices = New-Object System.Collections.ArrayList
        foreach ($n in $plan['notices']) { [void]$notices.Add($n) }
        if ($results.Count -gt 0) {
            try {
                $c = Invoke-Api 'POST' "$base/api/sync/v4/commit" @{ plan_id = $plan['plan_id']; results = $results } $token
                Remove-Item -LiteralPath $pendingFile -Force -ErrorAction SilentlyContinue
                foreach ($n in $c['notices']) { [void]$notices.Add($n) }
                $count.conflicts += [int]$c['summary']['conflict']
            } catch [SyncHttpError] {
                # Nothing is lost: the next run re-plans and converges.
                $code = Exit-ForHttp $_.Exception
                Write-Log $root "COMMIT-FAILED device=$($device['device_name']) error=$($_.Exception.Message)"
                return $code
            }
        }
        if ($notices.Count -gt 0) { Add-Notices $root $notices }

        $warn = @($notices | Where-Object { $_['level'] -ne 'info' }).Count
        $held = [int]$plan['summary']['held_deletes']
        $line = "OK device=$($device['device_name'] -replace '\s', '-') trigger=$trigger folders=$(@($plan['folders']).Count) " +
            "pull=$($count.pull) push=$($count.push) conflicts=$($count.conflicts) deletes=$($count.deletes) " +
            "held_deletes=$held skipped=$($count.skipped) failed=$($count.failed) notices=$($notices.Count)"
        Write-Log $root $line
        if (-not $Quiet -or $warn -gt 0 -or $count.failed -gt 0) { Out-Line $line }
        if ($warn -gt 0 -or $held -gt 0) { return 2 }
        return 0
    } finally { Exit-Lock $root }
}

function Invoke-AllRoots([string]$onlyFile, [string]$trigger) {
    $roots = Get-Roots
    if ($roots.Count -eq 0) {
        if ($onlyFile) { return 0 }  # hooks stay silent until sync is set up
        Say "Context Accelerator sync isn't set up on this computer yet. Say 'set up Context Accelerator sync' to Claude."
        return 1
    }
    $worst = 0
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            if (-not $onlyFile) { Say "Sync folder $root is missing. Was it moved? Run setup again with the new location." ; $worst = [Math]::Max($worst, 2) }
            continue
        }
        if ($onlyFile) {
            $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\')
            if (-not ([IO.Path]::GetFullPath($onlyFile)).StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
        }
        $code = Invoke-Sync $root $onlyFile $trigger
        if ($code -gt $worst) { $worst = $code }
    }
    return $worst
}

# -- setup / reset-token / status ---------------------------------------------

function Invoke-Setup([bool]$reset) {
    $claim = [string]$Opt['claim']
    if (-not $claim) { Out-Line "Missing --claim <code>"; return 1 }
    $root = [string]$Opt['root']
    if ($reset -and -not $root) { $root = @(Get-Roots)[0] }
    if (-not $root) { Out-Line "Missing --root <folder>"; return 1 }
    $root = [IO.Path]::GetFullPath($root).TrimEnd('\')
    $base = [string]$Opt['base']
    $existing = Read-JsonFile (Join-Path (Get-StateDir $root) 'device.json')
    if (-not $base -and $existing) { $base = $existing['base_url'] }
    if (-not $base) { Out-Line "Missing --base <url>"; return 1 }
    $base = $base.TrimEnd('/')

    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    Initialize-StateDir $root
    try {
        $r = Invoke-Api 'POST' "$base/api/sync/v4/devices/claim" @{ code = $claim; platform = 'windows'; client_version = $ClientVersion } $null
    } catch [SyncHttpError] {
        Out-Line "Setup failed: $($_.Exception.Message)"
        return $(if ($_.Exception.Status -eq 0) { 4 } else { 3 })
    }
    Save-Token $r['device_id'] $r['device_token']
    $device = @{
        device_id = $r['device_id']; device_name = $r['device_name']; base_url = $base
        company_id = $r['company_id']; company_name = $r['company_name']; folders = @()
    }
    if ($existing -and $existing['device_id'] -eq $r['device_id']) { $device['folders'] = @($existing['folders']) }
    Write-JsonFile (Join-Path (Get-StateDir $root) 'device.json') $device
    Add-Root $root
    Out-Line "OK setup device=$($r['device_name']) company=$($r['company_name']) root=$root"
    # Scheduled runs are optional: a failure here never fails setup.
    try { [void](Enable-Scheduled $root) } catch { Out-Line "Scheduled runs not enabled: $($_.Exception.Message)" }
    return 0
}

function Show-Status {
    $roots = Get-Roots
    if ($roots.Count -eq 0) { Out-Line "Sync isn't set up on this computer."; return 1 }
    foreach ($root in $roots) {
        $d = Read-JsonFile (Join-Path (Get-StateDir $root) 'device.json')
        Out-Line "Folder:  $root"
        if ($d) {
            Out-Line "Device:  $($d['device_name']) ($($d['device_id']))"
            Out-Line "Company: $($d['company_name']) ($($d['company_id']))"
            Out-Line "Server:  $($d['base_url'])"
            Out-Line "Token:   $(if (Read-Token $d['device_id']) { 'stored' } else { 'missing - reconnect sync' })"
            $sched = Test-Path -LiteralPath (Join-Path (Get-StateDir $root) 'scheduled-token')
            Out-Line "Scheduled runs: $(if ($sched) { 'enabled' } else { 'not enabled - run enable-scheduled' })"
        }
        $log = Join-Path (Get-StateDir $root) 'sync.log'
        if (Test-Path -LiteralPath $log) { Out-Line "Last:    $((Get-Content -LiteralPath $log -Tail 1 -Encoding UTF8))" }
        $pending = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '_SYNC-NOTICES.md' -File -ErrorAction SilentlyContinue)
        Out-Line "Notices: $($pending.Count) folder(s) with _SYNC-NOTICES.md"
        Out-Line "Log:     $log"
        Out-Line ""
    }
    return 0
}

function Invoke-RestoreHeld {
    $worst = 0
    foreach ($root in (Get-Roots)) {
        $d = Read-JsonFile (Join-Path (Get-StateDir $root) 'device.json')
        if (-not $d) { continue }
        $token = Read-Token $d['device_id']
        try {
            [void](Invoke-Api 'POST' "$(([string]$d['base_url']).TrimEnd('/'))/api/sync/v4/restore-held-deletes" @{} $token)
            Out-Line "Held deletes in $root will be restored on the next sync."
        } catch [SyncHttpError] { $worst = [Math]::Max($worst, (Exit-ForHttp $_.Exception)) }
    }
    if ($worst -eq 0) { $worst = Invoke-AllRoots $null 'restore' }
    return $worst
}

function Read-HookPath {
    # Claude Code hooks send a JSON object on stdin; Write/Edit carry tool_input.file_path.
    try {
        $raw = [Console]::In.ReadToEnd()
        if (-not $raw) { return $null }
        $o = $Json.DeserializeObject($raw)
        if ($o['tool_input'] -and $o['tool_input']['file_path']) { return [string]$o['tool_input']['file_path'] }
    } catch { }
    return $null
}

# -- main -----------------------------------------------------------------------

$code = 1
try {
    switch ($Command.ToLower()) {
        'setup' { $code = Invoke-Setup $false }
        'reset-token' { $code = Invoke-Setup $true }
        'status' { $code = Show-Status }
        'restore-held' { $code = Invoke-RestoreHeld }
        'enable-scheduled' { $code = Invoke-ForRoots { param($r) Enable-Scheduled $r } }
        'disable-scheduled' { $code = Invoke-ForRoots { param($r) Disable-Scheduled $r } }
        'run' {
            $trigger = if ($Opt['trigger']) { [string]$Opt['trigger'] } else { 'manual' }
            $code = Invoke-AllRoots ([string]$Opt['path']) $trigger
        }
        'hook' {
            $Quiet = $true
            $kind = if ($Rest.Count -gt 0) { $Rest[0] } else { 'session-start' }
            if ($kind -eq 'post-edit') {
                $p = Read-HookPath
                $code = if ($p) { Invoke-AllRoots $p 'post_edit' } else { 0 }
            } else { $code = Invoke-AllRoots $null 'session_start' }
            # Hooks never block Claude: problems surface on the next scheduled run.
            $code = 0
        }
        default { Out-Line "Usage: ca-sync setup|run|hook|status|reset-token|restore-held|enable-scheduled|disable-scheduled"; $code = 1 }
    }
} catch {
    Out-Line "Sync error: $($_.Exception.GetBaseException().Message)"
    if ($env:CA_SYNC_DEBUG) { Out-Line $_.ScriptStackTrace }
    $code = 1
}
exit $code
