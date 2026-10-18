<powershell>
$ErrorActionPreference = 'Stop'
$ProgressPreference   = 'SilentlyContinue'

$Log = 'C:\ProgramData\userdata.log'
New-Item -Path $Log -ItemType File -Force | Out-Null

Start-Transcript -Path $Log -Append -Force

try {
    $VerbosePreference     = 'Continue'
    $InformationPreference = 'Continue'
    $WarningPreference     = 'Continue'

    Write-Output "Starting PowerShell user-data at $(Get-Date -Format o)"

    Write-Output "Installing AD management features"
    Install-WindowsFeature -Name GPMC,RSAT-AD-PowerShell,RSAT-AD-AdminCenter,RSAT-ADDS-Tools,RSAT-DNS-Server
    Write-Output "AD management features installed"

    Write-Output "Downloading AWS CLI v2"
    Invoke-WebRequest https://awscli.amazonaws.com/AWSCLIV2.msi -OutFile C:\Users\Administrator\AWSCLIV2.msi

    Write-Output "Installing AWS CLI v2"
    Start-Process msiexec -ArgumentList "/i C:\Users\Administrator\AWSCLIV2.msi /qn" -Wait -NoNewWindow
    $env:Path += ";C:\Program Files\Amazon\AWSCLIV2"
    Write-Output "AWS CLI installed"

    Write-Output "Retrieving domain join credentials from Secrets Manager"
    $secretValue  = aws secretsmanager get-secret-value --secret-id ${admin_secret} --query SecretString --output text
    $secretObject = $secretValue | ConvertFrom-Json

    $password = $secretObject.password | ConvertTo-SecureString -AsPlainText -Force
    $cred     = New-Object System.Management.Automation.PSCredential ($secretObject.username, $password)

    Write-Output "Joining AD domain ${domain_fqdn}"
    Add-Computer -DomainName "${domain_fqdn}" -Credential $cred -Force
    Write-Output "Domain join command completed"

    Write-Output "Adding MCLOUD\mcloud-users to Remote Desktop Users"
    $domainGroup = "MCLOUD\mcloud-users"
    $maxRetries  = 10
    $retryDelay  = 30

    for ($i = 1; $i -le $maxRetries; $i++) {
        try {
            Write-Output "Attempt $i : Add-LocalGroupMember $domainGroup"
            Add-LocalGroupMember -Group "Remote Desktop Users" -Member $domainGroup -ErrorAction Stop
            Write-Output "SUCCESS: Added $domainGroup to Remote Desktop Users"
            break
        } catch {
            Write-Output "WARN: Attempt $i failed - waiting $retryDelay seconds..."
            Start-Sleep -Seconds $retryDelay
        }
    }

    # --------------------------------------------------------------------------
    # WebDAV client: the redirector, trust for the gateway's certificate, and
    # the settings that let it sign in with Kerberos like SMB does.
    # --------------------------------------------------------------------------
    Write-Output "Installing the WebDAV redirector (WebClient)"
    Install-WindowsFeature -Name WebDAV-Redirector

    Write-Output "Trusting the gateway's self-signed certificate"
    $certFile = "C:\ProgramData\webdav-gateway.cer"
    for ($i = 1; $i -le 60; $i++) {
        try {
            Invoke-WebRequest -UseBasicParsing "http://${samba_server}/cert.pem" -OutFile $certFile
            break
        } catch {
            Write-Output "WARN: Attempt $i : gateway certificate not ready - waiting 30 seconds..."
            Start-Sleep -Seconds 30
        }
    }
    if (Test-Path $certFile) {
        Import-Certificate -FilePath $certFile -CertStoreLocation Cert:\LocalMachine\Root
    } else {
        Write-Output "ERROR: gateway certificate never arrived; W: will not connect"
    }

    # The redirector only sends Windows credentials (Kerberos) to sites in the
    # Local Intranet zone, and a dotted host name is Internet zone by default.
    Write-Output "Mapping the gateway into the Local Intranet zone"
    $zoneKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMapKey"
    New-Item -Path $zoneKey -Force | Out-Null
    New-ItemProperty -Path $zoneKey -Name "https://${samba_server}" -Value "1" -PropertyType String -Force | Out-Null

    # The WebClient service only exists after the reboot that finishes the
    # redirector install, so its settings go in a one-time startup task.
    Write-Output "Scheduling WebClient settings for after the reboot"
    $setupScript = "C:\ProgramData\webclient-setup.ps1"
    Set-Content -Path $setupScript -Encoding ASCII -Value @'
$key = "HKLM:\SYSTEM\CurrentControlSet\Services\WebClient\Parameters"
# Send Windows credentials to the gateway even though it isn't an intranet name.
New-ItemProperty -Path $key -Name AuthForwardServerList -Value @("https://${samba_server}") -PropertyType MultiString -Force
# Raise the default 50 MB per-file limit to the maximum, 0xFFFFFFFF (4 GB).
New-ItemProperty -Path $key -Name FileSizeLimitInBytes -Value 0xFFFFFFFF -PropertyType DWord -Force
Set-Service -Name WebClient -StartupType Automatic
Restart-Service -Name WebClient
Unregister-ScheduledTask -TaskName webclient-setup -Confirm:$false
'@
    $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File $setupScript"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    Register-ScheduledTask -TaskName webclient-setup -Action $action -Trigger $trigger `
        -User SYSTEM -RunLevel Highest -Force | Out-Null

    # --------------------------------------------------------------------------
    # rclone: a third-party WebDAV client mounted as R:. It reads files in
    # ranges instead of downloading them whole, so it has no 4 GB limit.
    # It can't do Kerberos, so it signs in with Basic auth as jsmith, and one
    # mount made by SYSTEM at boot serves every user.
    # --------------------------------------------------------------------------
    Write-Output "Installing WinFsp and rclone"
    $rcloneDir = "C:\rclone"
    New-Item -ItemType Directory -Path $rcloneDir -Force | Out-Null

    $winfsp = (Invoke-RestMethod https://api.github.com/repos/winfsp/winfsp/releases/latest).assets |
        Where-Object name -like "*.msi" | Select-Object -First 1
    Invoke-WebRequest -UseBasicParsing $winfsp.browser_download_url -OutFile "$rcloneDir\winfsp.msi"
    Start-Process msiexec -ArgumentList "/i $rcloneDir\winfsp.msi /qn" -Wait -NoNewWindow

    Invoke-WebRequest -UseBasicParsing https://downloads.rclone.org/rclone-current-windows-amd64.zip -OutFile "$rcloneDir\rclone.zip"
    Expand-Archive "$rcloneDir\rclone.zip" "$rcloneDir\zip" -Force
    Copy-Item (Get-ChildItem "$rcloneDir\zip" -Recurse -Filter rclone.exe).FullName "$rcloneDir\rclone.exe" -Force
    Remove-Item "$rcloneDir\zip", "$rcloneDir\rclone.zip", "$rcloneDir\winfsp.msi" -Recurse -Force

    # Remote config with jsmith's password (rclone-obscured, which is
    # reversible), readable only by SYSTEM and Administrators.
    $jsmith = aws secretsmanager get-secret-value --secret-id jsmith_ad_credentials_webdav --query SecretString --output text | ConvertFrom-Json
    $obscured = & "$rcloneDir\rclone.exe" obscure $jsmith.password
    Set-Content -Path "$rcloneDir\rclone.conf" -Encoding ASCII -Value @(
        "[efs]",
        "type = webdav",
        "url = https://${samba_server}/efs",
        "vendor = other",
        "user = jsmith",
        "pass = $obscured"
    )
    icacls "$rcloneDir\rclone.conf" /inheritance:r /grant:r "SYSTEM:F" "Administrators:F" | Out-Null

    # Mount loop, restarted if rclone exits. Settings:
    #   vfs-cache-mode full    range reads into a local cache; writes cached,
    #                          then uploaded whole on close
    #   vfs-write-back 0s      start the upload as soon as the file closes
    #   vfs-handle-caching 0s  close the file at once (default keeps it 5 s)
    #   dir-cache-time 30s     see other protocols' changes within 30 s (5 min
    #                          by default). Not lower: Windows lists a large
    #                          folder in batches, and if the cache expires
    #                          mid-listing rclone re-fetches it; at 1 s a
    #                          1,000-file listing never finished.
    #   rc on localhost        benchmark.ps1 polls it for pending uploads
    Set-Content -Path "$rcloneDir\mount.ps1" -Encoding ASCII -Value @'
while ($true) {
    & C:\rclone\rclone.exe mount efs: R: --config C:\rclone\rclone.conf `
        --network-mode --volname \\rclone\efs `
        --vfs-cache-mode full --vfs-write-back 0s --vfs-handle-caching 0s `
        --dir-cache-time 30s --cache-dir C:\rclone\cache `
        --vfs-cache-max-size 10G --vfs-cache-max-age 10m `
        --rc --rc-addr 127.0.0.1:5572 --rc-no-auth `
        --log-file C:\rclone\mount.log --log-level INFO
    Start-Sleep -Seconds 15
}
'@
    $action   = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File $rcloneDir\mount.ps1"
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName rclone-mount -Action $action `
        -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $settings `
        -User SYSTEM -RunLevel Highest -Force | Out-Null
    Write-Output "rclone mount (R:) scheduled for startup"

    Write-Output "Creating persistent drive mappings (Z: SMB, W: WebDAV)"
    $startup   = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
    $batchFile = Join-Path $startup "map_drives.bat"
    $command   = @(
        "net use Z: \\${samba_server}\efs /persistent:yes",
        "net use W: \\${samba_server}@SSL\efs /persistent:yes"
    )
    Set-Content -Path $batchFile -Value $command -Encoding ASCII
    Write-Output "Drive mapping script created"

    Write-Output "Rebooting to finalize domain join"
    shutdown /r /t 5 /c "Initial EC2 reboot to join domain" /f /d p:4:1
}
finally {
    Write-Output "User-data finishing at $(Get-Date -Format o)"
    Stop-Transcript | Out-Null
}
</powershell>
