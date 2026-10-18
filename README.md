# Amazon EFS on Windows: SMB vs WebDAV vs rclone

Amazon EFS speaks only NFS, and Windows has no practical NFS client for it.
To use EFS from Windows, something has to translate. This project builds the
common ways side by side on **one Linux gateway, one EFS mount and one Active
Directory**, so the only thing that differs is the client and protocol:

- **SMB**: Samba shares `/efs` as `\\<gateway>\efs`. Windows maps it as `Z:`.
- **WebDAV, Windows client**: Apache `mod_dav` serves the same `/efs` at
  `https://<gateway>/efs`. Windows' built-in WebDAV redirector maps it as `W:`.
- **WebDAV, rclone**: [rclone](https://rclone.org) mounts the same URL as
  `R:`. It's the usual answer to the built-in client's 4 GB file limit.

`Z:` and `W:` sign in with the user's AD account, without a password prompt.
A benchmark then times the same file operations over all three.

## Architecture

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="architecture-dark.svg">
  <img alt="A Windows Server client maps the same Amazon EFS directory three times through a Linux gateway: as Z: over SMB on port 445 to Samba, and as W: (Windows' WebDAV redirector) and R: (rclone) over WebDAV on HTTPS port 443 to Apache mod_dav. The gateway mounts EFS over NFS with TLS. Both servers are members of the mini-AD domain controller, which issues their Kerberos tickets and reaches the internet through a NAT gateway, and both read credentials from Secrets Manager. You reach Windows over RDP and the gateway over SSH." src="architecture-light.svg">
</picture>

Regenerate with `python3 make_diagram.py`.

| Piece | Where | Role |
|---|---|---|
| **Linux gateway** (Ubuntu 24.04) | public subnet | mounts EFS over NFS + TLS; runs Samba (SMB) and Apache `mod_dav` (WebDAV) on that mount; joined to AD |
| **Windows Server 2022** | public subnet | the client: `Z:` over SMB, `W:` over WebDAV, `R:` over WebDAV with rclone; joined to AD |
| **Amazon EFS** | mount targets in 2 AZs | the shared file system, encrypted at rest |
| **mini-AD** (Samba DC) | private subnet | users, groups, DNS, Kerberos |
| **NAT gateway** | public subnet | outbound internet for the DC |

- **`01-directory/`**: the VPC and the
  [`module-aws-mini-ad`](https://github.com/mamonaco1973/module-aws-mini-ad)
  domain controller, with users and POSIX attributes from `users.json`.
- **`02-servers/`**: EFS, the gateway, the Windows client and their
  security groups. The WebDAV setup is in
  [`scripts/userdata.sh`](02-servers/scripts/userdata.sh) (gateway) and
  [`scripts/userdata.ps1`](02-servers/scripts/userdata.ps1) (Windows).

## How each path works

### SMB (`Z:`)

Samba runs as a domain member (`security = ads`). Windows connects on port
445 and signs in with the logged-on user's credentials. Here that's NTLM,
passed through to the DC: the `ec2.internal` name Windows uses has no SPN on
the gateway's computer account, so Kerberos isn't attempted. Samba maps the AD user to
their POSIX identity through SSSD, then reads and writes EFS **as that
user**. A file jsmith creates is owned by `jsmith` on EFS, exactly as if
jsmith had written it on Linux. `force group = mcloud-users` keeps shared
files group-writable.

### WebDAV (`W:`)

Apache serves `/efs` over HTTPS with `mod_dav_fs`. `mod_auth_gssapi`
accepts **Kerberos** (the `Negotiate` scheme) from domain-joined clients,
and Basic over TLS, checked against the same KDC, from everything else.
At boot the gateway registers the service principal
`HTTP/<gateway>.ec2.internal` on its AD computer account, so Windows can get
a ticket for it.

Apache is one process with one Unix account, so every file written over
WebDAV is owned by `www-data`, whoever signed in. Apache runs with group
`mcloud-users` and umask 007, which keeps those files usable from SMB.

The Windows side needs more setup than SMB. All of it is done in
`userdata.ps1`:

| Windows setting | Why |
|---|---|
| Install the `WebDAV-Redirector` feature | Windows Server ships without the WebClient service; it appears only after a reboot. |
| Trust the gateway's certificate (`LocalMachine\Root`) | WebClient refuses an untrusted certificate outright, with no "continue anyway". The gateway publishes it at `http://<gateway>/cert.pem`. |
| Put `https://<gateway>` in the Local Intranet zone | WebClient sends Windows credentials (Kerberos) only to intranet-zone sites, and a dotted host name counts as Internet zone. |
| `AuthForwardServerList` | Lets WebClient forward credentials to that server. |
| `FileSizeLimitInBytes` = 4 GB | The default limit is 50 MB per file; larger copies fail. 4 GB is the maximum. |

The gateway side needs one Apache workaround: Windows asks for folders without
a trailing slash and won't follow Apache's redirect for `PROPFIND`,
`PROPPATCH` or `DELETE`. `BrowserMatch "^Microsoft-WebDAV-MiniRedir"
redirect-carefully` turns that redirect off. Without it, folder deletes and
timestamp updates fail.

### rclone (`R:`)

rclone talks to the same Apache WebDAV share, and mounts it as a drive with
the [WinFsp](https://winfsp.dev) file-system driver. `userdata.ps1` installs
both and starts the mount at boot. Unlike Windows' client, rclone:

- **has no 4 GB limit**, and reads files in ranges (HTTP `Range` requests)
  into a local cache, so it doesn't download a whole file before an app can
  read it (`--vfs-cache-mode full`);
- **can't do Kerberos.** It signs in with a username and password over
  Basic auth. Here a single mount, started by SYSTEM, serves every user and
  signs in as jsmith;
- **writes to a local cache and uploads on close**, in the background. The
  app's close returns before the data is on the server.

Settings that matter, all in `C:\rclone\mount.ps1`:

| Flag | Why |
|---|---|
| `--vfs-cache-mode full` | Range reads; the mode Windows apps need for read-write files. |
| `--vfs-write-back 0s` | Start uploading as soon as a file closes (default 5 s). |
| `--vfs-handle-caching 0s` | Actually close the file at once (default holds it 5 s). |
| `--dir-cache-time 30s` | See other clients' new files within 30 s. The default is **5 minutes**, which hides files written over SMB or `W:`. Don't go much lower: Windows lists a big folder in batches, and if the cache expires partway, rclone re-fetches the folder. At 1 s, a 1,000-file listing never finished. |
| `--network-mode` | Show `R:` as a network drive to every user. |

## The three compared

| | SMB (`Z:`) | WebDAV, Windows client (`W:`) | WebDAV, rclone (`R:`) |
|---|---|---|---|
| **Port** | 445; commonly blocked by ISPs and between networks | 443; passes almost any firewall or proxy | 443 |
| **Single sign-on** | works out of the box on a domain member (NTLM here; Kerberos with a `cifs/` SPN) | Kerberos, but only after the zone and credential-forwarding settings above | none: username and password (Basic) |
| **Identity on EFS** | the real user (`jsmith:mcloud-users 770`) | always Apache (`www-data:mcloud-users 660`) | always Apache |
| **Who can access** | POSIX permissions per user on EFS | any domain user who signs in, then whatever `www-data` can reach | whoever the mount signs in as |
| **Windows ACLs** | mapped to POSIX mode bits | none | none |
| **File size limit** | none in practice | 50 MB by default; **4 GB maximum** | none |
| **Reading a large file** | streamed in place | **whole file** downloaded to a local cache first | ranges fetched as read, into a local cache |
| **Writing a file** | streamed as written | cached locally, uploaded whole on close | cached locally, uploaded whole after close, in the background |
| **Locking** | SMB byte-range locks and leases | WebDAV `LOCK` on whole files | local only; other clients don't see rclone's locks |
| **Seeing other clients' changes** | up to about 10 s (client folder cache) | no delay seen in testing | up to 30 s here (5 min by default) |
| **Files it leaves on EFS** | none | `.DAV/` property folders | none |
| **Client setup** | none | install a feature, reboot, trust a certificate, three registry settings | install WinFsp and rclone, store a password, run a mount at startup |
| **Non-Windows clients** | Samba, macOS, Linux CIFS | any HTTP tool, browsers, macOS Finder, `davfs2` | rclone runs on Linux and macOS too |

## Benchmark

**Full results, charts and what they mean for SAS workloads:
[PERFORMANCE-REPORT.md](PERFORMANCE-REPORT.md).** Raw output is in
[`results/`](results/).

[`benchmark.ps1`](benchmark.ps1) runs on the Windows client and times the
same operations through `Z:`, `W:` and `R:` against the same EFS folder.
Reads, listings and deletes use files a **different** client wrote, so no
client's cache can answer locally; untimed pauses let each client's folder
cache catch up first. rclone's write times run until rclone has completed one
upload per file written. Median of 3 runs, `t3.medium` instances, EFS in
bursting mode:

| Operation | SMB (`Z:`) | WebDAV (`W:`) | rclone (`R:`) |
|---|---|---|---|
| 1 GB write | 12.4 s (83 MB/s) | 24.3 s (42 MB/s) | 25.5 s (40 MB/s) |
| 1 GB read | 2.2 s (457 MB/s) | 37.9 s (27 MB/s) | 14.0 s (73 MB/s) |
| 1,000 × 4 KB write | 48.2 s | 245.4 s | 115.1 s |
| List 1,000 files | 2.60 s | **0.35 s** | 9.27 s |
| 1,000 × 4 KB read | 5.0 s | 61.7 s | 107.5 s |
| Rename folder | 0.05 s | 0.59 s | 3.61 s |
| Delete 1,000 files | 27.3 s | 51.6 s | 93.4 s |

[`bigfile.ps1`](bigfile.ps1) copies one 5 GB file through each drive and
checks each copy on the server with SHA-256: SMB and rclone produce exact
copies; Windows' WebDAV client fails and leaves a locked 1 GiB fragment.

```bash
./benchmark.sh                                      # 3 runs, about 55 minutes
./benchmark.sh -Runs 1 -LargeMB 64 -SmallCount 50   # quick check, about 3 minutes
./bigfile.sh                                        # 5 GB test, about 10 minutes
python3 make_report_charts.py results/benchmark.txt # redraw the report's charts
```

## When to use which

- **SMB** for Windows users working on the share every day: it's faster,
  keeps per-user ownership and permissions on EFS, and needs no client setup
  on a domain member.
- **WebDAV** when port 445 can't get through (remote users, locked-down
  networks, crossing an internet boundary), when clients aren't Windows, or
  for occasional file transfer where per-user ownership doesn't matter.
  Use **rclone** rather than Windows' client when files can exceed 4 GB or
  apps read parts of large files, and accept a stored password instead of
  single sign-on.
- **Neither**, if Windows is the main client and you can change storage:
  **FSx for Windows File Server** is native SMB with Windows ACLs, and
  **FSx for NetApp ONTAP** serves the same data over NFS and SMB.

## Cross-protocol gotchas

Found while building this. Each one is handled in the code:

- **Samba's NetBIOS name must match its AD computer account.** realm join
  names the account after the hostname (`IP-10-0-0-125$`). If `smb.conf`
  uses any other name, Samba's trust with the DC breaks (`wbinfo -t` fails)
  and every SMB logon gets `NT_STATUS_LOGON_FAILURE`.
- **The gateway has two DNS names.** The DC's DHCP options give it
  `ip-10-0-0-125.mcloud.mikecloud.com`; Windows connects to
  `ip-10-0-0-125.ec2.internal`. The certificate and the `HTTP/` service
  principal must use the name the client types, so the gateway builds the
  `ec2.internal` name from its IP.
- **Deleting over WebDAV a file Windows has open over SMB.** Windows keeps
  handles to files it read over SMB cached for a while, so Samba still has
  them open. When Apache deletes such a file, the NFS client renames it to
  `.nfsXXXX` instead, and the folder can't be removed ("directory not empty").
  The benchmark has each protocol delete the folder it was reading, not the
  one the other protocol has open.
- **SMB clients don't see other clients' new files at once.** Windows' SMB
  client caches folder contents for about 10 seconds
  (`DirectoryCacheLifetime`) and remembers "not found" for about 5
  (`FileNotFoundCacheLifetime`). A file written over WebDAV can be invisible
  on `Z:` for that long. rclone's own directory cache defaults to 5 minutes, and setting it very low backfires: at 1 second, rclone never finished listing a 1,000-file folder, because the cache expired while Windows was still reading it.
- **Apache's 1 GiB upload limit.** Since Apache 2.4.53, `LimitRequestBody`
  defaults to 1 GiB, so any WebDAV upload larger than that gets
  `413 Request Entity Too Large`, from any client. The WebDAV share sets
  `LimitRequestBody 0`.
- **`.DAV/` folders and DOS attributes.** Samba reports dot-folders as
  hidden, and it can't change attributes on EFS, which has no extended
  attributes. So PowerShell's `Remove-Item -Force`, which clears the Hidden
  attribute first, fails on `.DAV/` with "The request is not supported";
  `[IO.Directory]::Delete` works.

## Prerequisites

* [An AWS Account](https://aws.amazon.com/console/)
* [Install AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
* [Install Terraform](https://developer.hashicorp.com/terraform/install)
* [Install jq](https://jqlang.github.io/jq/download/)

## Deploy

```bash
git clone https://github.com/mamonaco1973/aws-webdav.git
cd aws-webdav
./apply.sh       # 1: VPC + mini-AD  2: EFS, gateway, Windows; then validate.sh
```

`validate.sh` waits for the gateway's setup. Then, over SSM and as jsmith, it
checks SMB, WebDAV with Basic and with Kerberos, and a file written each way
reads back over the other protocol. It ends with:

```
EFS over SMB and WebDAV
=======================
File owner : SMB    -> jsmith:mcloud-users 770  (the signed-in user)
             WebDAV -> www-data:mcloud-users 660  (Apache's account)
Windows    : RDP to ec2-54-162-194-86.compute-1.amazonaws.com
             Z: = \\ip-10-0-0-125.ec2.internal\efs       (SMB)
             W: = \\ip-10-0-0-125.ec2.internal@SSL\efs   (WebDAV)
             R: = rclone over the same WebDAV URL (as jsmith)
             Needs ~10 minutes after deploy to join the domain.
Linux      : SSH to ec2-3-82-8-222.compute-1.amazonaws.com
Sign in    : MCLOUD\jsmith / orange-481920
Benchmark  : ./benchmark.sh
```

The Windows host needs about **10 minutes** after deploy to join the domain
and reboot. The reboot also finishes the WebDAV redirector install.

## Try it

1. RDP to the Windows host as `MCLOUD\jsmith`. `Z:` and `W:` connect at
   sign-in with no password prompt; `R:` is already mounted. All three show
   the same `data` and `home` folders.
2. Create a file on `W:` and open it from `Z:` and `R:`, and the other way
   round.
3. SSH to the gateway as jsmith and run `ls -l /efs/data`. Files you made
   on `Z:` are owned by `jsmith`; files from `W:` by `www-data`.
4. In a `W:` folder you've edited, look at `/efs/data/<folder>/.DAV` on the
   gateway: the properties Windows stored over WebDAV.
5. On the gateway, `sudo tail -f /var/log/apache2/webdav-access.log` while
   copying a file to `W:` shows each HTTP request, signed in as
   `jsmith@MCLOUD.MIKECLOUD.COM`.

User passwords are in Secrets Manager as `<user>_ad_credentials_webdav`:

```bash
aws secretsmanager get-secret-value --secret-id jsmith_ad_credentials_webdav \
  --query SecretString --output text | jq -r .password
```

Users and groups (from `01-directory/scripts/users.json.template`):

| User | Groups |
|---|---|
| jsmith | mcloud-users, us, linux-admins, Domain Admins |
| edavis | mcloud-users, us |
| rpatel | mcloud-users, india, linux-admins, Domain Admins |
| akumar | mcloud-users, india |

## Troubleshooting

| Symptom | Fix |
|---|---|
| `validate.sh`: gateway user data failed | `aws ssm start-session --target <gateway_instance_id>`, then `sudo cat /root/userdata.log`; the last lines show the failing step. |
| SMB: every logon fails | On the gateway, `sudo wbinfo -t`. If the trust check fails, `netbios name` in `/etc/samba/smb.conf` doesn't match the computer account (`hostname -s`, upper case). |
| `W:` asks for a password | Kerberos isn't being sent. Check the zone entry under `HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMapKey`, and `klist` for an `HTTP/<gateway>` ticket. |
| `W:`: "The network name cannot be found" | WebClient isn't running (`Get-Service WebClient`) or the certificate isn't trusted. The service appears only after the first reboot. |
| Copy to `W:` fails for a large file | Over the WebClient size limit (`FileSizeLimitInBytes`, 4 GB maximum). |
| A `W:` folder won't delete: "not empty" | Look for `.nfsXXXX` files in it on the gateway: something still has those files open over SMB. They disappear when it closes them. |
| `R:` is missing | `C:\rclone\mount.log`. The `rclone-mount` scheduled task restarts rclone 15 s after it exits. |
| A new file doesn't show on `Z:` | Windows' SMB folder cache: wait about 10 seconds. |
| WebDAV over `curl` works but Windows fails on folders | Check for `301` responses in `webdav-access.log`; the `redirect-carefully` line must be in `/etc/apache2/sites-available/webdav.conf`. |

## Teardown

```bash
./destroy.sh     # destroys the servers and EFS, deletes the secrets, destroys the directory
```

## Notes

- **Lab only.** Both servers have public IPs; SSH, RDP and SMB are open to the
  internet. WebDAV (443) and the certificate download (80) are limited to the VPC.
- The certificate is self-signed for the gateway's `ec2.internal` name.
- rclone stores jsmith's password in `C:\rclone\rclone.conf`, "obscured",
  which is reversible, not encrypted; the file is readable only by SYSTEM and
  Administrators. Its remote-control API (used by the benchmark) listens on
  `127.0.0.1:5572` without authentication.
- Apache reads a copy of the gateway's machine keytab
  (`/etc/apache2/http.keytab`), so the gateway turns off machine-password
  rotation in both Samba and SSSD. If you turn it back on, refresh the copy
  from `/etc/krb5.keytab` after each rotation.
