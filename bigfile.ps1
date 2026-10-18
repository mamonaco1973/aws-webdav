# ==============================================================================
# bigfile.ps1 - Files over 4 GB through Z: (SMB), W: (WebDAV) and R: (rclone)
# ------------------------------------------------------------------------------
#   Runs on the Windows client; bigfile.sh sends it over SSM.
#
#   1. Writes one file of -SizeGB (default 5) through each drive and times it.
#      Windows' WebDAV client caps files at 4 GB, so W: is expected to fail.
#   2. Reads the first 10 MB of the SMB-written file through R: and W:, to
#      show whether a client must fetch the whole file before reading.
#   3. Prints the source SHA-256 so bigfile.sh can compare it with the copies
#      on the gateway.
#
#   Connects as jsmith with the password from Secrets Manager (SSM runs as
#   SYSTEM, which has no domain identity). Leaves the files in
#   \\<server>\efs\data\bigfile for bigfile.sh to check, then remove.
# ==============================================================================
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$SizeGB = 5
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$rclone  = "C:\rclone\rclone.exe"
$smbRoot = "\\$Server\efs"
$davRoot = "\\$Server@SSL\efs"
$src     = Join-Path $env:TEMP "bigfile-src.bin"

$secret = & "C:\Program Files\Amazon\AWSCLIV2\aws.exe" secretsmanager get-secret-value `
    --secret-id jsmith_ad_credentials_webdav --query SecretString --output text `
    --region us-east-1 | ConvertFrom-Json
foreach ($root in @($smbRoot, $davRoot)) {
    cmd /c "net use $root /delete /y >nul 2>&1"
    $out = cmd /c "net use $root `"$($secret.password)`" /user:$($secret.username) 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "net use $root failed: $out" }
}

# Source file: 1 MB of random bytes repeated, each MB stamped so no two
# blocks are identical.
if (-not (Test-Path $src) -or (Get-Item $src).Length -ne $SizeGB * 1GB) {
    $buf = New-Object byte[] (1MB)
    (New-Object Random 42).NextBytes($buf)
    $fs = [IO.File]::Create($src)
    for ($i = 0; $i -lt $SizeGB * 1024; $i++) {
        $buf[0] = [byte]($i % 256); $buf[1] = [byte](($i -shr 8) % 256)
        $fs.Write($buf, 0, $buf.Length)
    }
    $fs.Close()
}
Write-Output ("source_sha256 {0}" -f (Get-FileHash $src -Algorithm SHA256).Hash)

$dir = "$smbRoot\data\bigfile"
if (Test-Path $dir) { [IO.Directory]::Delete($dir, $true) }
New-Item -ItemType Directory -Path $dir | Out-Null
Start-Sleep -Seconds 31          # let rclone's 30 s folder cache see it

# rclone registers the upload a moment after close returns, so wait for its
# completed-transfer count to rise rather than for an empty queue.
function Get-RcloneTransfers {
    (& $rclone rc --url http://127.0.0.1:5572/ core/stats | ConvertFrom-Json).transfers
}

$targets = @(
    @{ Name = "smb";    Path = "$dir\smb.bin" },
    @{ Name = "webdav"; Path = "$davRoot\data\bigfile\dav.bin" },
    @{ Name = "rclone"; Path = "R:\data\bigfile\rcl.bin" }
)
foreach ($t in $targets) {
    $base = if ($t.Name -eq "rclone") { Get-RcloneTransfers } else { 0 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        [IO.File]::Copy($src, $t.Path, $true)
        if ($t.Name -eq "rclone") {
            while ((Get-RcloneTransfers) -lt $base + 1) { Start-Sleep -Milliseconds 200 }
        }
        Write-Output ("write {0} ok {1:N1}" -f $t.Name, $sw.Elapsed.TotalSeconds)
    } catch {
        $msg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        Write-Output ("write {0} failed {1:N1} {2}" -f $t.Name, $sw.Elapsed.TotalSeconds, $msg.Trim())
    }
}

# Partial read of a file neither client has cached: the SMB-written copy.
Start-Sleep -Seconds 31
$reads = @(
    @{ Name = "rclone"; Path = "R:\data\bigfile\smb.bin" },
    @{ Name = "webdav"; Path = "$davRoot\data\bigfile\smb.bin" }
)
foreach ($t in $reads) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $f = [IO.File]::OpenRead($t.Path)
        $b = New-Object byte[] (10MB); $n = 0
        while ($n -lt 10MB) { $n += $f.Read($b, $n, 10MB - $n) }
        $f.Close()
        Write-Output ("read10mb {0} ok {1:N2}" -f $t.Name, $sw.Elapsed.TotalSeconds)
    } catch {
        $msg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        Write-Output ("read10mb {0} failed {1:N2} {2}" -f $t.Name, $sw.Elapsed.TotalSeconds, $msg.Trim())
    }
}
Remove-Item $src -Force -ErrorAction SilentlyContinue
