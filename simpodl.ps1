<#
  SimpoDownloader for Windows - resumable, never-give-up downloader.
  Needs NOTHING extra: runs on the PowerShell that ships with Windows 10/11.

  Survives network drops, "connection was reset", "bytes missing", stalled
  downloads (speed stuck at 0) and power cuts - just run it again to resume.

  Install (PowerShell, one line):
    irm https://raw.githubusercontent.com/nambobi/SimpoDownloader/main/install.ps1 | iex

  Then, from ANY terminal (cmd or PowerShell):
    simpodl                        asks for the folder, then the link
    simpodl "<link>"               download into the current folder
    simpodl "<link>" "D:\Data"     download into D:\Data (created if missing)
    simpodl resume                 resume all unfinished downloads
    simpodl update                 get the newest version from GitHub
    simpodl help
#>
param(
    [string]$Url,
    [string]$Out,
    [string]$Name,
    [string]$Checksum,
    [switch]$Resume
)

$ErrorActionPreference = 'Stop'
$Version         = '1.3'
$RepoRaw         = 'https://raw.githubusercontent.com/nambobi/SimpoDownloader/main'
$RepoPage        = 'https://github.com/nambobi/SimpoDownloader'
$ChunkSize       = 256KB   # bytes read per loop
$CheckpointEvery = 8MB     # force data onto the disk every 8 MB (power-cut safety)
$StallTimeout    = 45      # seconds with no data before we reconnect
$MaxBackoff      = 60      # longest wait between retries (seconds)

$OnWindows = ($env:OS -eq 'Windows_NT')
$UserHome  = [Environment]::GetFolderPath('UserProfile')
if (-not $UserHome) { $UserHome = $HOME }
$StateDir    = Join-Path $UserHome '.simpodownloader'
$PendingFile = Join-Path $StateDir 'pending.json'
$LogFile     = Join-Path $StateDir 'download.log'
$InstallDir  = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'SimpoDownloader' } else { $null }
$ProgressPreference = 'SilentlyContinue'   # makes Invoke-WebRequest much faster in Windows PowerShell

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}  # TLS 1.2

# ------------------------------------------------------------------ output helpers
function Get-Width {
    try { $w = $Host.UI.RawUI.WindowSize.Width; if ($w -gt 20) { return $w } } catch {}
    return 100
}
function Clear-Line { Write-Host ("`r" + (' ' * ((Get-Width) - 1)) + "`r") -NoNewline }
function Say([string]$Msg, [string]$Color) {
    Clear-Line
    if ($Color) { Write-Host $Msg -ForegroundColor $Color } else { Write-Host $Msg }
}
function Write-Log([string]$Msg) {
    try {
        if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        Add-Content -LiteralPath $LogFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss ') + $Msg)
    } catch {}
}
function Format-Size($n) {
    if ($null -eq $n) { return '?' }
    $n = [double]$n
    foreach ($u in 'B', 'KB', 'MB', 'GB', 'TB') {
        if ([Math]::Abs($n) -lt 1024 -or $u -eq 'TB') {
            if ($u -eq 'B') { return ('{0:N0} B' -f $n) } else { return ('{0:N2} {1}' -f $n, $u) }
        }
        $n = $n / 1024
    }
}
function Format-Time($s) {
    if ($null -eq $s -or $s -lt 0 -or $s -gt 356400) { return '--:--:--' }
    $s = [long]$s
    return ('{0}:{1:D2}:{2:D2}' -f [long][Math]::Floor($s / 3600), [long][Math]::Floor(($s % 3600) / 60), [long]($s % 60))
}

# ------------------------------------------------------------------ folders and names
function Get-KnownFolders {
    $f = [ordered]@{
        Desktop   = [Environment]::GetFolderPath('Desktop')      # follows OneDrive redirection
        Documents = [Environment]::GetFolderPath('MyDocuments')
        Downloads = (Join-Path $UserHome 'Downloads')
    }
    if ($OnWindows) {
        try {
            $d = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
            if ($d) { $f.Downloads = $d }
        } catch {}
    }
    if (-not $f.Desktop)   { $f.Desktop   = Join-Path $UserHome 'Desktop' }
    if (-not $f.Documents) { $f.Documents = Join-Path $UserHome 'Documents' }
    return $f
}
function Resolve-UserPath([string]$p) {
    $p = $p.Trim().Trim('"').Trim("'")          # "Copy as path" adds quotes
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if ($p.StartsWith('~')) { $p = $UserHome + $p.Substring(1) }
    # relative paths are relative to the folder the terminal is in
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)
}
function Get-SafeName([string]$n) {
    $n = [Uri]::UnescapeDataString($n).Trim()
    $n = ($n -replace '[<>:"/\\|?*\x00-\x1f]', '_').TrimEnd('.', ' ')
    if (-not $n) { $n = 'download.bin' }
    return $n
}
function Get-DispositionName([string]$cd) {
    if (-not $cd) { return $null }
    if ($cd -match "filename\*\s*=\s*[^']*''([^;]+)") { return [Uri]::UnescapeDataString($matches[1].Trim('"', ' ')) }
    if ($cd -match 'filename\s*=\s*"?([^";]+)"?') { return $matches[1].Trim() }
    return $null
}

# ------------------------------------------------------------------ keep PC awake
if ($OnWindows) {
    try {
        Add-Type -Namespace Simpo -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);' -ErrorAction Stop
    } catch {}
}
function Set-KeepAwake([bool]$On) {
    if (-not $OnWindows) { return }
    try {
        if ($On) { [void][Simpo.Power]::SetThreadExecutionState([uint32]2147483649) }
        else     { [void][Simpo.Power]::SetThreadExecutionState([uint32]2147483648) }
    } catch {}
}

# ------------------------------------------------------------------ JSON state files
function Read-JsonFile([string]$path) {
    try { if (Test-Path -LiteralPath $path) { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } } catch {}
    return $null
}
function Write-JsonFile([string]$path, $obj) {
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 5))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}
function Get-Pending {
    $p = Read-JsonFile $PendingFile
    if ($null -eq $p) { return @() }
    return @($p)
}
function Save-Pending($list) {
    try {
        if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        Write-JsonFile $PendingFile @($list)
    } catch {}
}
function Add-Pending($job) {
    $list = @(Get-Pending | Where-Object { $_.dest -ne $job.dest })
    $list += [pscustomobject]@{ dest = $job.dest; url = $job.url; checksum = $job.checksum; added = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
    Save-Pending $list
}
function Remove-Pending([string]$dest) { Save-Pending @(Get-Pending | Where-Object { $_.dest -ne $dest }) }

# ------------------------------------------------------------------ network helpers
function New-Request([string]$u) {
    $r = [Net.HttpWebRequest]::Create($u)
    $r.UserAgent = "SimpoDownloader/$Version (PowerShell)"
    $r.AllowAutoRedirect = $true
    $r.Timeout = 30000
    $r.ReadWriteTimeout = $StallTimeout * 1000
    $r.AutomaticDecompression = [Net.DecompressionMethods]::None
    return $r
}

# Turns any error into plain English. Returns @{ msg; fatal; wait; code }
function Get-Reason($ex) {
    $chain = @(); $e = $ex
    while ($e) { $chain += $e; $e = $e.InnerException }
    foreach ($e in $chain) {
        if ($e -is [Net.WebException] -and $e.Response) {
            $code = [int]$e.Response.StatusCode
            if (@(400, 401, 403, 404, 410) -contains $code) {
                return @{ fatal = $true; code = $code; msg = "Server says HTTP $code - the link is wrong, private or expired." }
            }
            $wait = $null
            $ra = $e.Response.Headers['Retry-After']
            if ($ra -match '^\d+$') { $wait = [int]$ra }
            if ($code -eq 429) { if (-not $wait) { $wait = 60 }; return @{ code = 429; wait = $wait; msg = 'Server says too many requests (HTTP 429) - slowing down' } }
            return @{ code = $code; wait = $wait; msg = "Server error HTTP $code" }
        }
    }
    foreach ($e in $chain) {
        if ($e -is [Net.Sockets.SocketException]) {
            switch ([string]$e.SocketErrorCode) {
                'ConnectionReset'   { return @{ msg = 'Connection was reset by the server/network' } }
                'ConnectionAborted' { return @{ msg = 'Connection was aborted' } }
                'TimedOut'          { return @{ msg = "Download stalled - no data for $StallTimeout s" } }
                'HostNotFound'      { return @{ msg = 'No internet (cannot find the server) - waiting for the network' } }
                'TryAgain'          { return @{ msg = 'No internet (cannot find the server) - waiting for the network' } }
                'NetworkUnreachable'{ return @{ msg = 'No internet (network unreachable) - waiting for the network' } }
                'ConnectionRefused' { return @{ msg = 'Connection refused by the server' } }
            }
        }
        if ($e -is [Net.WebException]) {
            switch ([string]$e.Status) {
                'NameResolutionFailure' { return @{ msg = 'No internet (cannot find the server) - waiting for the network' } }
                'Timeout'               { return @{ msg = "Download stalled - no data for $StallTimeout s" } }
                'ConnectFailure'        { return @{ msg = 'Could not connect to the server' } }
                'ConnectionClosed'      { return @{ msg = 'Server closed the connection' } }
                'ReceiveFailure'        { return @{ msg = 'Connection dropped while receiving data' } }
                'SecureChannelFailure'  { return @{ msg = 'Secure connection (TLS) failed' } }
            }
        }
        if ($e -is [TimeoutException] -or $e -is [Threading.Tasks.TaskCanceledException]) {
            return @{ msg = "Download stalled - no data for $StallTimeout s" }
        }
        if ($e -is [IO.IOException] -and ($e.HResult -band 0xFFFF) -eq 112) {
            return @{ fatal = $true; msg = 'Disk is full! Free some space and run again to resume.' }
        }
    }
    foreach ($e in $chain) {
        if ($e -is [IO.IOException]) { return @{ msg = "Connection dropped mid-download ($($e.Message))" } }
    }
    return @{ msg = $ex.Message }
}

function Get-RemoteInfo([string]$u) {
    $wait = 5
    while ($true) {
        $req = $null
        try {
            $req = New-Request $u
            $req.AddRange([long]0, [long]0)
            $resp = $req.GetResponse()
            try {
                $h = $resp.Headers
                $code = [int]$resp.StatusCode
                $info = @{ url = $resp.ResponseUri.AbsoluteUri; ranges = $false; total = $null
                           etag = $h['ETag']; lastmod = $h['Last-Modified']; name = (Get-DispositionName $h['Content-Disposition']) }
                if ($code -eq 206) {
                    if ($h['Content-Range'] -match '/(\d+)\s*$') { $info.total = [long]$matches[1] }
                    $info.ranges = $true
                } else {
                    if ($resp.ContentLength -ge 0) { $info.total = [long]$resp.ContentLength }
                    $info.ranges = ($h['Accept-Ranges'] -eq 'bytes')
                }
                return $info
            } finally { $req.Abort(); $resp.Close() }
        } catch {
            $r = Get-Reason $_.Exception
            if ($r.fatal) { throw "FATAL: $($r.msg)" }
            Say "Could not reach the server: $($r.msg). Trying again in $wait s..." Yellow
            Start-Sleep -Seconds $wait
            $wait = [Math]::Min($wait * 2, $MaxBackoff)
        }
    }
}

function Get-ZenodoChecksum([string]$u, [string]$fileName) {
    if ($u -notmatch 'zenodo\.org/(?:api/)?records?/(\d+)/files/([^/?#]+)') { return $null }
    $id = $matches[1]; $want = [Uri]::UnescapeDataString($matches[2])
    try {
        $data = Invoke-RestMethod -Uri "https://zenodo.org/api/records/$id" -TimeoutSec 20 -UseBasicParsing
        foreach ($f in $data.files) { if ($f.key -eq $want -or $f.key -eq $fileName) { return $f.checksum } }
    } catch {}
    return $null
}

# ------------------------------------------------------------------ checksum
function ConvertTo-Checksum([string]$text) {
    if (-not $text) { return $null }
    $text = $text.Trim().ToLower()
    if ($text.Contains(':')) { $algo, $value = $text.Split(':', 2) }
    else {
        $value = $text
        $algo = @{ 32 = 'md5'; 40 = 'sha1'; 64 = 'sha256'; 128 = 'sha512' }[$text.Length]
    }
    if (@('md5', 'sha1', 'sha256', 'sha384', 'sha512') -notcontains $algo -or $value -notmatch '^[0-9a-f]+$') { return $null }
    return @{ algo = $algo; value = $value }
}

# ------------------------------------------------------------------ the core download loop
function Invoke-Download($job) {
    $u = $job.url; $dest = $job.dest; $info = $job.info
    $part = "$dest.part"; $metaPath = "$dest.part.json"
    $total = $info.total
    $leaf = Split-Path -Leaf $dest

    # --- recover from a previous run (including a power cut) ---
    $old = Read-JsonFile $metaPath
    $meta = @{ url = $u; etag = $info.etag; lastmod = $info.lastmod; total = $total; checkpoint = 0 }
    if (Test-Path -LiteralPath $part) {
        $size = (Get-Item -LiteralPath $part).Length
        if ($old -and $old.url -and $old.url -ne $u) {
            Say 'A partial file from a DIFFERENT link exists - starting fresh.' Yellow
            Move-Item -LiteralPath $part -Destination "$part.old" -Force
        } else {
            if ($old -and $null -ne $old.checkpoint -and [long]$old.checkpoint -lt $size) {
                # After a power cut the file can end in data that never really reached the disk.
                # Trim back to the last point we KNOW was saved safely.
                $fs = [IO.File]::Open($part, 'Open', 'ReadWrite'); $fs.SetLength([long]$old.checkpoint); $fs.Close()
                Say ("Recovered after unexpected shutdown - trimmed {0} of unsafe data." -f (Format-Size ($size - [long]$old.checkpoint))) Yellow
            }
            if ($old -and $old.etag -and $info.etag -and $old.etag -ne $info.etag) {
                Say 'The file on the server has changed since last time - starting over.' Yellow
                $fs = [IO.File]::Open($part, 'Open', 'ReadWrite'); $fs.SetLength(0); $fs.Close()
            }
        }
    }
    if (-not (Test-Path -LiteralPath $part)) { [IO.File]::WriteAllBytes($part, [byte[]]@()) }
    $meta.checkpoint = (Get-Item -LiteralPath $part).Length
    Write-JsonFile $metaPath $meta
    Add-Pending $job

    $attempt = 0; $wait = 5; $fatal = $null
    $buf = New-Object byte[] $ChunkSize
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $sessionBytes = [long]0

    while ($true) {
        [long]$have = (Get-Item -LiteralPath $part).Length
        if ($null -ne $total -and $have -ge $total) { break }
        $attempt++
        if ($have -gt 0) { Say ("--- Attempt #{0}: resuming {1} from {2} ---" -f $attempt, $leaf, (Format-Size $have)) Cyan }
        else             { Say ("--- Attempt #{0}: downloading {1} ---" -f $attempt, $leaf) Cyan }
        Write-Log "attempt $attempt $dest from byte $have"
        $before = $have; $resp = $null; $fs = $null; $req = $null
        $samples = New-Object System.Collections.ArrayList
        $lastDraw = -1.0
        try {
            $req = New-Request $u
            if ($have -gt 0) {
                $req.AddRange([long]$have)
                $validator = $info.etag; if (-not $validator) { $validator = $info.lastmod }
                if ($validator) { try { $req.Headers.Add('If-Range', $validator) } catch {} }
            }
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            if ($have -gt 0 -and $code -eq 200) {
                Say 'Server ignored the resume request - restarting from 0 (it does not support resuming).' Yellow
                $have = 0
            } elseif ($code -eq 206) {
                if ($resp.Headers['Content-Range'] -match 'bytes\s+(\d+)-' -and [long]$matches[1] -ne $have) {
                    throw [IO.IOException]'Server resumed from the wrong position'
                }
            }
            if ($null -eq $total -and $resp.ContentLength -ge 0) {
                if ($code -eq 206) { $total = $have + $resp.ContentLength } else { $total = [long]$resp.ContentLength }
            }
            $stream = $resp.GetResponseStream()
            try { $stream.ReadTimeout = $StallTimeout * 1000 } catch {}
            $fs = [IO.File]::Open($part, 'OpenOrCreate', 'ReadWrite', 'Read')
            $fs.SetLength($have); [void]$fs.Seek($have, 'Begin')
            $since = 0
            while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                $fs.Write($buf, 0, $n)
                $have += $n; $since += $n; $sessionBytes += $n
                if ($since -ge $CheckpointEvery) {
                    $fs.Flush($true)                  # really write to disk
                    $meta.checkpoint = $have; Write-JsonFile $metaPath $meta
                    $since = 0
                }
                # --- progress line (redrawn twice a second) ---
                $now = $clock.Elapsed.TotalSeconds
                if ($now - $lastDraw -ge 0.5) {
                    $lastDraw = $now
                    [void]$samples.Add(@($now, $have))
                    while ($samples.Count -gt 16) { $samples.RemoveAt(0) }
                    $t0 = $samples[0][0]; $b0 = $samples[0][1]
                    $speed = 0; if ($now -gt $t0) { $speed = ($have - $b0) / ($now - $t0) }
                    $avg = 0; if ($now -gt 0) { $avg = $sessionBytes / $now }
                    if ($total) {
                        $pct = $have * 100.0 / $total
                        $fill = [int][Math]::Floor(20 * $have / $total)
                        $eta = $null; if ($speed -gt 0) { $eta = ($total - $have) / $speed }
                        $line = "  [{0}{1}] {2,5:N1}%  {3} / {4}  | {5}/s (avg {6}/s)  | ETA {7}  | try #{8}" -f `
                            ('#' * $fill), ('.' * (20 - $fill)), $pct, (Format-Size $have), (Format-Size $total),
                            (Format-Size $speed), (Format-Size $avg), (Format-Time $eta), $attempt
                    } else {
                        $line = "  {0} downloaded  | {1}/s  | try #{2}" -f (Format-Size $have), (Format-Size $speed), $attempt
                    }
                    $w = Get-Width
                    if ($line.Length -gt $w - 1) { $line = $line.Substring(0, $w - 1) }
                    Write-Host ("`r" + $line.PadRight($w - 1)) -NoNewline
                }
            }
            Write-Host ''
            if ($null -ne $total -and $have -lt $total) {
                throw [IO.IOException]('Server closed the connection early ({0} missing)' -f (Format-Size ($total - $have)))
            }
            if ($null -eq $total) { break }   # unknown size + clean end = done
        } catch {
            $r = Get-Reason $_.Exception
            if ($r.code -eq 416 -and $null -ne $total -and (Get-Item -LiteralPath $part).Length -ge $total) { break }
            if ($r.fatal) { $fatal = $r.msg; break }
            if ($have -gt $before) { $wait = 5 }            # we made progress: reset the back-off
            if ($r.wait) { $wait = $r.wait }
            Write-Host ''
            $pctTxt = if ($total) { '{0:N1}% saved' -f ($have * 100.0 / $total) } else { (Format-Size $have) + ' saved' }
            Say "Download interrupted: $($r.msg) ($pctTxt)" Yellow
            Write-Log "interrupted: $($r.msg) at $have"
            for ($s = [int]$wait; $s -gt 0; $s--) {
                Write-Host ("`r  Retrying in {0,2}s...  (Ctrl+C to pause - you can resume later)" -f $s) -NoNewline -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
            Clear-Line
            $wait = [Math]::Min($wait * 2, $MaxBackoff)
        } finally {
            if ($fs) {
                try { $fs.Flush($true) } catch {}
                $fs.Close()
                $meta.checkpoint = (Get-Item -LiteralPath $part).Length
                Write-JsonFile $metaPath $meta
            }
            if ($resp) { try { $resp.Close() } catch {} }
        }
    }

    if ($fatal) { Say "STOPPED: $fatal" Red; Write-Log "fatal $dest : $fatal"; return $false }

    # --- finished: size check, rename, verify ---
    $final = (Get-Item -LiteralPath $part).Length
    if ($null -ne $total -and $final -ne $total) { Say "Size mismatch: got $final bytes, expected $total." Red; return $false }
    if (Test-Path -LiteralPath $dest) { Move-Item -LiteralPath $dest -Destination "$dest.previous" -Force }
    Move-Item -LiteralPath $part -Destination $dest
    Remove-Item -LiteralPath $metaPath -Force -ErrorAction SilentlyContinue
    Remove-Pending $dest
    Write-Log "done $dest $final bytes"
    Say ("Downloaded {0} -> {1}" -f (Format-Size $final), $dest) Green

    $ck = ConvertTo-Checksum $job.checksum
    if ($ck) {
        Say ("  Verifying {0} checksum (big files take a minute)..." -f $ck.algo.ToUpper()) DarkGray
        $got = (Get-FileHash -LiteralPath $dest -Algorithm $ck.algo.ToUpper()).Hash.ToLower()
        if ($got -eq $ck.value) {
            Say ("Checksum OK ({0} matches) - the file is intact." -f $ck.algo.ToUpper()) Green
        } else {
            Say "CHECKSUM MISMATCH!  expected $($ck.value)" Red
            Say "                    got      $got" Red
            Say 'The file is corrupted. Delete it and download again.' Red
            Write-Log "checksum mismatch $dest"
            return $false
        }
    }
    return $true
}

# ------------------------------------------------------------------ interactive prompts
function Ask([string]$Prompt, [string]$Default) {
    $suffix = ''; if ($Default) { $suffix = " [$Default]" }
    $a = Read-Host "$Prompt$suffix"
    if (-not $a) { return $Default }
    return $a.Trim()
}

function Select-Folder {
    $f = Get-KnownFolders
    $here = (Get-Location).Path
    Say "`nWhere should the file be saved?" Cyan
    Write-Host "  Enter      = this folder  " -NoNewline; Write-Host $here -ForegroundColor DarkGray
    Write-Host "  1 / 2 / 3  = Desktop / Documents / Downloads"
    Write-Host "  or type/paste any folder path (created if it does not exist)"
    while ($true) {
        $c = Ask 'Folder' ''
        if (-not $c)       { $p = $here }
        elseif ($c -eq '1') { $p = $f.Desktop }
        elseif ($c -eq '2') { $p = $f.Documents }
        elseif ($c -eq '3') { $p = $f.Downloads }
        else { $p = Resolve-UserPath $c }
        if (Test-Path -LiteralPath $p -PathType Container) { Say "Saving to: $p" Green; return $p }
        if (Test-Path -LiteralPath $p) { Say 'That path is a file, not a folder. Try again.' Red; continue }
        try {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
            Say "Folder did not exist - created it: $p" Green
            return $p
        } catch { Say "Could not create folder: $($_.Exception.Message)" Red }
    }
}

function Read-Url {
    while ($true) {
        $u = (Ask "`nPaste the download link" '').Trim('"', "'", ' ')
        if ($u -match '^https?://\S+$') { return $u }
        Say 'That does not look like a web link (must start with http:// or https://).' Yellow
    }
}

function Test-DiskSpace([string]$folder, $need, [bool]$interactive) {
    if (-not $need -or $need -le 0) { return $true }
    try {
        $free = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($folder))).AvailableFreeSpace
    } catch { return $true }
    if ($free -lt $need) {
        Say ("Not enough disk space: need {0}, only {1} free on that drive." -f (Format-Size $need), (Format-Size $free)) Red
        if (-not $interactive) { return $false }
        return ((Ask 'Continue anyway? (y/n)' 'n') -like 'y*')
    }
    Say ("Disk space OK: {0} free, file needs {1}." -f (Format-Size $free), (Format-Size $need)) DarkGray
    return $true
}

function New-Job([string]$u, [string]$folder, [string]$fileName, [string]$ck, [bool]$interactive) {
    Say 'Checking the link...' DarkGray
    $info = Get-RemoteInfo $u
    $suggest = $fileName
    if (-not $suggest) { $suggest = $info.name }
    if (-not $suggest) { $suggest = [IO.Path]::GetFileName(([Uri]$info.url).AbsolutePath) }
    $suggest = Get-SafeName $suggest
    $sizeTxt = if ($info.total) { Format-Size $info.total } else { 'unknown' }
    if ($info.ranges) { Say "  Size: $sizeTxt   Resume supported: yes" Green }
    else { Say "  Size: $sizeTxt   Resume supported: NO (a drop means starting over)" Yellow }
    if (-not $folder) { if ($interactive) { $folder = Select-Folder } else { $folder = (Get-Location).Path } }
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $dest = Join-Path $folder $suggest

    if ($interactive -and $info.total -and (Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -eq $info.total) {
        Say 'A file with that name and the same size already exists.' Yellow
        if ((Ask 'Download again anyway? (y/n)' 'n') -notlike 'y*') { return $null }
    }
    if (-not $ck) {
        $ck = Get-ZenodoChecksum $u $suggest
        if ($ck) { Say "  Found official checksum on Zenodo: $ck" Green }
    }
    $have = 0; if (Test-Path -LiteralPath "$dest.part") { $have = (Get-Item -LiteralPath "$dest.part").Length }
    $need = $null; if ($info.total) { $need = $info.total - $have }
    if (-not (Test-DiskSpace $folder $need $interactive)) { return $null }
    return @{ url = $u; dest = $dest; info = $info; checksum = $ck }
}

function Get-ResumeJobs([bool]$auto) {
    $pending = @(Get-Pending | Where-Object { $_ -and $_.dest -and (Test-Path -LiteralPath "$($_.dest).part") })
    Save-Pending $pending
    if ($pending.Count -eq 0) { if ($auto) { Say 'Nothing to resume.' DarkGray }; return @() }
    Say "`nUnfinished downloads found (from a power cut, network loss or Ctrl+C):" Yellow
    for ($i = 0; $i -lt $pending.Count; $i++) {
        $p = $pending[$i]
        Write-Host ("  {0}) {1}  - {2} saved  " -f ($i + 1), (Split-Path -Leaf $p.dest), (Format-Size (Get-Item -LiteralPath "$($p.dest).part").Length)) -NoNewline
        Write-Host (Split-Path -Parent $p.dest) -ForegroundColor DarkGray
    }
    if ($auto) { $a = 'a' } else { $a = Ask "Resume which? (number, 'a' = all, Enter = skip)" '' }
    $chosen = @()
    if ($a -eq 'a') { $chosen = $pending }
    elseif ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $pending.Count) { $chosen = @($pending[[int]$a - 1]) }
    $jobs = @()
    foreach ($p in $chosen) {
        $jobs += @{ url = $p.url; dest = $p.dest; info = (Get-RemoteInfo $p.url); checksum = $p.checksum }
    }
    return $jobs
}

function Invoke-Jobs($jobs) {
    $ok = $true
    Set-KeepAwake $true
    try {
        foreach ($j in $jobs) {
            $script:Busy = $true
            $r = Invoke-Download $j
            $script:Busy = $false
            if (-not $r) { $ok = $false }
        }
    } finally { Set-KeepAwake $false }
    try { [Console]::Beep(880, 250) } catch {}
    return $ok
}

# ------------------------------------------------------------------ updates
function Get-LatestVersion([int]$timeout) {
    try {
        $r = Invoke-WebRequest -Uri "$RepoRaw/VERSION" -UseBasicParsing -TimeoutSec $timeout -Headers @{ 'Cache-Control' = 'no-cache' }
        $v = ([string]$r.Content).Trim()
        if ($v -match '^\d+(\.\d+){1,3}$') { return $v }
    } catch {}
    return $null
}
function Test-Newer([string]$a, [string]$b) { try { return ([version]$a -gt [version]$b) } catch { return $false } }

function Invoke-Update {
    Say 'Checking GitHub for a newer version...' DarkGray
    $latest = Get-LatestVersion 15
    if (-not $latest) { Say "Could not reach GitHub ($RepoPage). Check your internet and try again." Red; return $false }
    if (-not (Test-Newer $latest $Version)) { Say "You already have the latest version ($Version)." Green; return $true }
    $target = $PSCommandPath
    $tmp = "$target.new"
    try {
        Invoke-WebRequest -Uri "$RepoRaw/simpodl.ps1" -UseBasicParsing -OutFile $tmp -TimeoutSec 60
        $errs = $null
        [void][Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$null, [ref]$errs)
        if ($errs.Count -gt 0 -or -not (Select-String -LiteralPath $tmp -Pattern 'SimpoDownloader' -Quiet)) { throw 'the downloaded file is damaged' }
        Copy-Item -LiteralPath $target -Destination "$target.bak" -Force
        Move-Item -LiteralPath $tmp -Destination $target -Force
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Say "Update failed: $($_.Exception.Message). Your current version still works." Red
        return $false
    }
    Say "Updated SimpoDownloader $Version -> $latest" Green
    try {
        $log = (Invoke-WebRequest -Uri "$RepoRaw/CHANGELOG.md" -UseBasicParsing -TimeoutSec 15).Content -split "`n"
        Say "`nWhat's new:" Cyan
        $n = 0
        foreach ($line in $log) {
            if ($line -match '^## ') { $n++; if ($n -gt 1) { break } }
            if ($n -ge 1 -and $line.Trim()) { Write-Host "  $($line.TrimEnd())" }
        }
    } catch {}
    Save-UpdateCheck
    return $true
}
function Save-UpdateCheck {
    try {
        if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        Set-Content -LiteralPath (Join-Path $StateDir 'last_update_check') -Value (Get-Date -Format o)
    } catch {}
}
function Show-UpdateNotice {
    # checks at most once a day, gives up after 3 seconds so it never slows you down
    try {
        $stamp = Join-Path $StateDir 'last_update_check'
        if ((Test-Path -LiteralPath $stamp) -and ((Get-Date) - (Get-Item -LiteralPath $stamp).LastWriteTime).TotalHours -lt 24) { return }
        Save-UpdateCheck
        $latest = Get-LatestVersion 3
        if ($latest -and (Test-Newer $latest $Version)) {
            Say "A new version $latest is available (you have $Version). Run:  simpodl update" Yellow
        }
    } catch {}
}

function Invoke-Uninstall {
    if (-not $InstallDir -or -not (Test-Path -LiteralPath $InstallDir)) { Say 'SimpoDownloader is not installed on this PC.' Yellow; return }
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        $old = [string]$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $new = (@($old -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $InstallDir.TrimEnd('\') })) -join ';'
        $k.SetValue('Path', $new, [Microsoft.Win32.RegistryValueKind]::ExpandString); $k.Close()
        [Environment]::SetEnvironmentVariable('SIMPODL_REFRESH', '1', 'User'); [Environment]::SetEnvironmentVariable('SIMPODL_REFRESH', $null, 'User')
    } catch {}
    # the folder is deleted a moment after this window's command finishes (it is in use right now)
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c ping -n 3 127.0.0.1 >nul & rmdir /s /q `"$InstallDir`"" -WindowStyle Hidden
    Say 'SimpoDownloader has been uninstalled. Your downloaded files are untouched.' Green
}

# ------------------------------------------------------------------ main
function Show-Help {
    Write-Host @"
SimpoDownloader $Version - resumable downloader that survives network drops and power cuts

Usage:
  simpodl "<link>"                  download into the folder you are in
  simpodl "<link>" "D:\Data"        download into D:\Data (created if missing)
  simpodl "<link>" -Name new.zip    save under a different name
  simpodl "<link>" -Checksum md5:.. verify the file after download
  simpodl                           asks for the folder, then the link
  simpodl resume                    resume all unfinished downloads
  simpodl update                    get the newest version from GitHub
  simpodl version                   show version
  simpodl uninstall                 remove SimpoDownloader from this PC

Project page: $RepoPage

Tip: put the link in "quotes" so symbols like & in it do not confuse the terminal.
"@
}
switch -Regex ("$Url") {
    '^(help|-h|--help|/\?|-\?)$' { Show-Help; exit 0 }
    '^(version|-v|--version)$'   { Write-Host "SimpoDownloader $Version"; exit 0 }
    '^resume$'                   { $Resume = $true; $Url = $null }
    '^update$'                   { if (Invoke-Update) { exit 0 } else { exit 1 } }
    '^uninstall$'                { Invoke-Uninstall; exit 0 }
}
if ($Url -and $Url -notmatch '^https?://') {
    Write-Host "Not a web link: $Url   (links must start with http:// or https://)" -ForegroundColor Red
    Show-Help; exit 1
}
$script:Busy = $false
$os = if ($OnWindows) { 'Windows' } else { [Environment]::OSVersion.Platform }
Say "=== SimpoDownloader $Version === running on $os" Cyan
Show-UpdateNotice
try {
    if ($Resume) { [void](Invoke-Jobs (Get-ResumeJobs $true)); return }
    if ($Url) {
        $folder = $null; if ($Out) { $folder = Resolve-UserPath $Out }
        $job = New-Job $Url $folder $Name $Checksum $false
        if (-not $job) { exit 1 }
        if (Invoke-Jobs @($job)) { Say 'SUCCESS! The file is fully downloaded.' Green; exit 0 } else { exit 1 }
    }
    $jobs = Get-ResumeJobs $false
    if ($jobs.Count -gt 0) { [void](Invoke-Jobs $jobs) }
    while ($true) {
        $folder = Select-Folder
        $job = New-Job (Read-Url) $folder $null $null $true
        if ($job) {
            if (Invoke-Jobs @($job)) { Say 'SUCCESS! The file is fully downloaded.' Green }
        }
        if ((Ask "`nDownload another file? (y/n)" 'n') -notlike 'y*') { break }
    }
} catch {
    if ("$($_.Exception.Message)" -like 'FATAL:*') { Say ("STOPPED: " + $_.Exception.Message.Substring(7)) Red }
    else { Say "Unexpected error: $($_.Exception.Message)" Red; Write-Log "unexpected: $($_ | Out-String)" }
} finally {
    if ($script:Busy) { Say "`nPaused. Progress is saved - run SimpoDownloader again and choose to resume." Yellow }
}
