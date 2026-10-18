# ==============================================================================
# benchmark.ps1 - SMB vs WebDAV vs rclone against the same EFS directory
# ------------------------------------------------------------------------------
#   Runs on the Windows client. benchmark.sh sends it over SSM; it also runs
#   from an RDP session: .\benchmark.ps1 -Server <gateway private DNS>
#
#   All three paths end in the same EFS directory on the gateway:
#     SMB     \\<server>\efs\data\<run>        Samba
#     WebDAV  \\<server>@SSL\efs\data\<run>    Windows' WebDAV redirector
#     rclone  R:\data\<run>                    rclone mount over the same WebDAV
#   rclone is skipped if R: isn't mounted.
#
#   Each run times the same operations over every protocol. Reads, listings
#   and deletes use files a *different* protocol wrote (SMB reads rclone's,
#   WebDAV reads SMB's, rclone reads WebDAV's), so no client's cache can
#   answer locally. rclone uploads in the background after a file closes, so
#   its write timings run until rclone has completed one upload per file
#   written. The table shows the median of all runs.
#
#   Unless -UseCurrentUser, SMB and WebDAV connect as jsmith with the password
#   from Secrets Manager (SSM runs as SYSTEM, which has no domain identity).
#   R: always signs in as jsmith (see userdata.ps1).
# ==============================================================================
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$Runs = 3,
    [int]$LargeMB = 1024,
    [int]$SmallCount = 1000,
    [int]$SmallKB = 4,
    [switch]$UseCurrentUser
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$smbRoot = "\\$Server\efs"
$davRoot = "\\$Server@SSL\efs"
$runName = "bench-" + (Get-Date -Format "yyyyMMdd-HHmmss")
$smbDir  = "$smbRoot\data\$runName"
$local   = Join-Path $env:TEMP "efs-bench"
$rclone  = "C:\rclone\rclone.exe"

# Name, the run folder as that protocol sees it, and a file-name prefix.
$protocols = @(
    @{ Name = "SMB";    Dir = $smbDir;                      Prefix = "smb" },
    @{ Name = "WebDAV"; Dir = "$davRoot\data\$runName";     Prefix = "dav" }
)
if (Test-Path "R:\data") {
    $protocols += @{ Name = "rclone"; Dir = "R:\data\$runName"; Prefix = "rcl" }
} else {
    Write-Output "NOTE: R: (rclone) not mounted - skipping rclone"
}
# Each protocol reads, lists and deletes what the previous one in the list
# wrote: SMB <- rclone (or WebDAV), WebDAV <- SMB, rclone <- WebDAV.
for ($i = 0; $i -lt $protocols.Count; $i++) {
    $protocols[$i].Source = $protocols[($i - 1 + $protocols.Count) % $protocols.Count].Prefix
}

# ------------------------------------------------------------------------------
# Connect both shares as jsmith
# ------------------------------------------------------------------------------
# net.exe through cmd: with ErrorActionPreference Stop, Windows PowerShell
# turns any native stderr line into a terminating error.
function Connect-Share([string]$Root) {
    cmd /c "net use $Root /delete /y >nul 2>&1"
    $out = cmd /c "net use $Root `"$($secret.password)`" /user:$($secret.username) 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "net use $Root failed: $out" }
}

if (-not $UseCurrentUser) {
    $aws    = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
    $secret = & $aws secretsmanager get-secret-value --secret-id jsmith_ad_credentials_webdav `
        --query SecretString --output text --region us-east-1 | ConvertFrom-Json
    foreach ($root in @($smbRoot, $davRoot)) { Connect-Share $root }
}

# ------------------------------------------------------------------------------
# Test data: one large file of random bytes, written locally once
# ------------------------------------------------------------------------------
New-Item -ItemType Directory -Path $local -Force | Out-Null
$bigFile = Join-Path $local "big.bin"
if (-not (Test-Path $bigFile) -or (Get-Item $bigFile).Length -ne $LargeMB * 1MB) {
    $buf = New-Object byte[] (1MB)
    (New-Object Random).NextBytes($buf)
    $fs = [IO.File]::Create($bigFile)
    for ($i = 0; $i -lt $LargeMB; $i++) { $fs.Write($buf, 0, $buf.Length) }
    $fs.Close()
}
$smallBytes = New-Object byte[] ($SmallKB * 1KB)
(New-Object Random).NextBytes($smallBytes)

New-Item -ItemType Directory -Path $smbDir | Out-Null

# ------------------------------------------------------------------------------
# Timing helpers
# ------------------------------------------------------------------------------
$results = @{}
function Measure-Op([string]$Name, [string]$Proto, [scriptblock]$Body) {
    $key = "$Name|$Proto"
    if (-not $results.ContainsKey($key)) { $results[$key] = New-Object System.Collections.ArrayList }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Body
        $sw.Stop()
        [void]$results[$key].Add($sw.Elapsed.TotalSeconds)
    } catch {
        $sw.Stop()
        [void]$results[$key].Add([double]::NaN)
        Write-Output "ERROR: $Name over $Proto - $($_.Exception.Message)"
    }
}

# rclone returns from close before the upload finishes, and registers the
# upload a moment later, so an empty upload queue proves nothing. Instead,
# count completed transfers: Get-RcloneTransfers before the write, then
# Wait-Uploads until that count has risen by the number of files written.
function Get-RcloneTransfers {
    (& $rclone rc --url http://127.0.0.1:5572/ core/stats | ConvertFrom-Json).transfers
}

function Wait-Uploads([string]$Proto, [long]$Base, [int]$Files) {
    if ($Proto -ne "rclone") { return }
    $deadline = (Get-Date).AddMinutes(30)
    while ((Get-RcloneTransfers) -lt $Base + $Files) {
        if ((Get-Date) -gt $deadline) { throw "rclone uploads not finished after 30 minutes" }
        Start-Sleep -Milliseconds 200
    }
}

function Write-Small([string]$Dir) {
    New-Item -ItemType Directory -Path $Dir | Out-Null
    for ($i = 0; $i -lt $SmallCount; $i++) {
        [IO.File]::WriteAllBytes("$Dir\f$i.dat", $smallBytes)
    }
}

function Read-Small([string]$Dir) {
    for ($i = 0; $i -lt $SmallCount; $i++) {
        [void][IO.File]::ReadAllBytes("$Dir\f$i.dat")
    }
}

function Assert-Count([string]$Dir) {
    $n = @(Get-ChildItem -Path $Dir -File).Count
    if ($n -ne $SmallCount) { throw "listed $n files, expected $SmallCount" }
}

# ------------------------------------------------------------------------------
# Runs
# ------------------------------------------------------------------------------
$largeLabel = if ($LargeMB -ge 1024) { "$($LargeMB / 1024) GB" } else { "$LargeMB MB" }
$smallLabel = "$SmallCount x $SmallKB KB"
$tmpRead    = Join-Path $local "read.bin"

for ($r = 1; $r -le $Runs; $r++) {
    Write-Output "Run $r of $Runs"

    foreach ($p in $protocols) {
        $base = if ($p.Name -eq "rclone") { Get-RcloneTransfers } else { 0 }
        Measure-Op "$largeLabel write" $p.Name {
            [IO.File]::Copy($bigFile, "$($p.Dir)\$($p.Prefix)_$r.bin", $true); Wait-Uploads $p.Name $base 1 }
    }
    # Untimed: clients cache folder contents - Windows' SMB client for 10 s
    # (DirectoryCacheLifetime), rclone for 30 s (--dir-cache-time) - so they
    # can't see another protocol's new files until that expires.
    Start-Sleep -Seconds 31
    foreach ($p in $protocols) {
        Measure-Op "$largeLabel read" $p.Name {
            [IO.File]::Copy("$($p.Dir)\$($p.Source)_$r.bin", $tmpRead, $true) }
        Remove-Item $tmpRead -Force -ErrorAction SilentlyContinue
    }

    foreach ($p in $protocols) {
        $base = if ($p.Name -eq "rclone") { Get-RcloneTransfers } else { 0 }
        Measure-Op "$smallLabel write" $p.Name {
            Write-Small "$($p.Dir)\$($p.Prefix)_small_$r"; Wait-Uploads $p.Name $base $SmallCount }
    }
    Start-Sleep -Seconds 31
    foreach ($p in $protocols) {
        Measure-Op "List $SmallCount files" $p.Name { Assert-Count "$($p.Dir)\$($p.Source)_small_$r" }
    }
    foreach ($p in $protocols) {
        Measure-Op "$smallLabel read" $p.Name { Read-Small "$($p.Dir)\$($p.Source)_small_$r" }
    }

    foreach ($p in $protocols) {
        Measure-Op "Rename folder" $p.Name {
            Rename-Item "$($p.Dir)\$($p.Prefix)_small_$r" "$($p.Prefix)_moved_$r" }
    }
    # Untimed: the folders were just renamed by another client; let folder
    # caches catch up before deleting by the new name.
    Start-Sleep -Seconds 31
    # Each protocol deletes the folder it has been reading, which another
    # protocol wrote. Windows keeps handles to files it read over SMB cached
    # open for a while; if Apache deletes such a file, NFS renames it to
    # .nfsXXXX instead and the folder delete fails as "not empty".
    foreach ($p in $protocols) {
        Measure-Op "Delete $SmallCount files" $p.Name {
            [IO.Directory]::Delete("$($p.Dir)\$($p.Source)_moved_$r", $true) }
    }

    foreach ($p in $protocols) {
        Remove-Item "$smbDir\$($p.Prefix)_$r.bin" -Force -ErrorAction SilentlyContinue
    }
}

# Directory.Delete rather than Remove-Item -Force: the latter first clears the
# Hidden attribute Samba reports on mod_dav_fs's .DAV folders, and Samba can't
# store DOS attributes on EFS (no extended attributes), so it fails.
try { [IO.Directory]::Delete($smbDir, $true) } catch { Write-Output "WARN: cleanup of $smbDir - $($_.Exception.Message)" }

# ------------------------------------------------------------------------------
# Results: median per operation
# ------------------------------------------------------------------------------
function Get-Median($values) {
    $v = @($values | Where-Object { -not [double]::IsNaN($_) } | Sort-Object)
    if ($v.Count -eq 0 -or $v.Count -lt @($values).Count) { return [double]::NaN }
    if ($v.Count % 2) { return $v[[int][math]::Floor($v.Count / 2)] }
    return ($v[$v.Count / 2 - 1] + $v[$v.Count / 2]) / 2
}

function Format-Time([double]$s, [string]$Op) {
    if ([double]::IsNaN($s)) { return "failed" }
    $text = "{0:N2} s" -f $s
    if ($Op -like "$largeLabel *") { $text += " ({0:N0} MB/s)" -f ($LargeMB / $s) }
    return $text
}

$ops = @(
    "$largeLabel write", "$largeLabel read",
    "$smallLabel write", "List $SmallCount files", "$smallLabel read",
    "Rename folder", "Delete $SmallCount files"
)

$names = @($protocols | ForEach-Object { $_.Name })
$head  = "{0,-20}" -f "Operation"
$rule  = "{0,-20}" -f "---------"
foreach ($n in $names) { $head += " {0,-19}" -f $n; $rule += " {0,-19}" -f ("-" * $n.Length) }
foreach ($n in $names | Select-Object -Skip 1) { $head += " {0,-11}" -f "$n/SMB"; $rule += " {0,-11}" -f ("-" * "$n/SMB".Length) }

Write-Output ""
Write-Output ("Median of {0} runs, \\{1}" -f $Runs, $Server)
Write-Output $head
Write-Output $rule
foreach ($op in $ops) {
    $line = "{0,-20}" -f $op
    $med  = @{}
    foreach ($n in $names) { $med[$n] = Get-Median $results["$op|$n"]; $line += " {0,-19}" -f (Format-Time $med[$n] $op) }
    foreach ($n in $names | Select-Object -Skip 1) {
        $ratio = if ([double]::IsNaN($med["SMB"]) -or [double]::IsNaN($med[$n]) -or $med["SMB"] -le 0) { "-" } else { "{0:N1}x" -f ($med[$n] / $med["SMB"]) }
        $line += " {0,-11}" -f $ratio
    }
    Write-Output $line
}
