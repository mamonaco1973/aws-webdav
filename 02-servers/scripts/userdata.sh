#!/bin/bash

set -euo pipefail

# Centralized user-data logging
LOG=/root/userdata.log
mkdir -p /root
touch "$LOG"
chmod 600 "$LOG"
exec > >(tee -a "$LOG" | logger -t user-data -s 2>/dev/console) 2>&1
trap 'echo "ERROR at line $LINENO"; exit 1' ERR

echo "user-data start: $(date -Is)"

# SSM agent
snap install amazon-ssm-agent --classic
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service

# Base packages
apt-get update -y
export DEBIAN_FRONTEND=noninteractive
apt-get install -y \
  less unzip realmd sssd-ad sssd-tools libnss-sss libpam-sss adcli \
  samba samba-common-bin samba-libs oddjob oddjob-mkhomedir packagekit \
  krb5-user nano vim nfs-common winbind libpam-winbind libnss-winbind stunnel4 \
  smbclient

# EFS utils
cd /tmp
git clone https://github.com/mamonaco1973/amazon-efs-utils.git
cd amazon-efs-utils
dpkg -i amazon-efs-utils*.deb
which mount.efs

# AWS CLI v2
cd /tmp
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

# EFS mounts
mkdir -p /efs
echo "${efs_mnt_server}:/ /efs efs _netdev,tls 0 0" >> /etc/fstab
systemctl daemon-reload
mount /efs

mkdir -p /efs/home /efs/data
echo "${efs_mnt_server}:/home /home efs _netdev,tls 0 0" >> /etc/fstab
systemctl daemon-reload
mount /home

# AD join
secretValue=$(aws secretsmanager get-secret-value \
  --secret-id ${admin_secret} \
  --query SecretString \
  --output text)

admin_password=$(echo "$secretValue" | jq -r '.password')
admin_username=$(echo "$secretValue" | jq -r '.username' | sed 's/.*\\//')

echo -e "$admin_password" | realm join \
  --membership-software=samba \
  -U "$admin_username" \
  ${domain_fqdn} \
  --verbose 

# SSH + SSSD tweaks
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' \
  /etc/ssh/sshd_config.d/60-cloudimg-settings.conf

sed -i 's/use_fully_qualified_names = True/use_fully_qualified_names = False/' \
  /etc/sssd/sssd.conf
sed -i 's/ldap_id_mapping = True/ldap_id_mapping = False/' \
  /etc/sssd/sssd.conf
sed -i 's|fallback_homedir = /home/%u@%d|fallback_homedir = /home/%u|' \
  /etc/sssd/sssd.conf
echo "ad_maximum_machine_account_password_age = 0" >> /etc/sssd/sssd.conf

touch /etc/skel/.Xauthority
chmod 600 /etc/skel/.Xauthority
pam-auth-update --enable mkhomedir
systemctl restart ssh

# Samba
systemctl stop sssd

cat > /tmp/smb.conf <<EOF
[global]
workgroup = ${netbios}
security = ads

strict sync = no
sync always = no
aio read size = 1
aio write size = 1
use sendfile = yes

passdb backend = tdbsam

printing = cups
printcap name = cups
load printers = yes
cups options = raw

kerberos method = secrets and keytab
# Keep the machine password fixed: Apache's keytab copy (below) would go
# stale on rotation, and SSSD and winbind would each try to rotate it.
machine password timeout = 0

template homedir = /home/%U
template shell = /bin/bash
#netbios

create mask = 0770
force create mode = 0770
directory mask = 0770
force group = ${force_group}

realm = ${realm}

idmap config ${realm} : backend = sss
idmap config ${realm} : range = 10000-1999999999
idmap config * : backend = tdb
idmap config * : range = 1-9999

winbind use default domain = yes
winbind normalize names = yes
winbind refresh tickets = yes
winbind offline logon = yes
winbind enum groups = yes
winbind enum users = yes
winbind cache time = 30
idmap cache time = 60
winbind negative cache time = 0

[homes]
browseable = no
read only = no
inherit acls = yes

[efs]
path = /efs
read only = no
guest ok = no
EOF

cp /tmp/smb.conf /etc/samba/smb.conf
rm /tmp/smb.conf

# The NetBIOS name must match the computer account realm join created
# (IP-10-0-0-x$, the hostname capped at 15 characters). Any other name breaks
# Samba's secure channel to the DC, and every SMB logon then fails.
netbios=$(hostname -s | cut -c1-15 | tr '[:lower:]' '[:upper:]')
sed -i "s/#netbios/netbios name=$netbios/" /etc/samba/smb.conf

cat > /tmp/nsswitch.conf <<EOF
passwd:     files sss winbind
group:      files sss winbind
automount:  files sss winbind
shadow:     files sss winbind
hosts:      files dns myhostname
services:   files sss
netgroup:   files sss
EOF

cp /tmp/nsswitch.conf /etc/nsswitch.conf
rm /tmp/nsswitch.conf

systemctl restart winbind smb nmb sssd

# ------------------------------------------------------------------------------
# WebDAV: Apache mod_dav serving the same /efs mount as the Samba [efs] share
# ------------------------------------------------------------------------------
# Clients reach it at https://<EC2 private DNS name>/efs. Windows maps that
# name, so the certificate and the Kerberos service principal both use it.
# It is built from the private IP: IMDS local-hostname and hostname -f return
# the AD domain suffix the DC's DHCP options set, not ec2.internal.
IMDS_TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
FQDN="ip-$(echo "$PRIVATE_IP" | tr . -).ec2.internal"
echo "WebDAV host name: $FQDN"

apt-get install -y apache2 libapache2-mod-auth-gssapi

# Kerberos client defaults. mod_auth_gssapi's Basic fallback turns a bare
# username into a principal using default_realm; rdns=false keeps the service
# name exactly as the client typed it.
cat > /etc/krb5.conf <<EOF
[libdefaults]
  default_realm    = ${realm}
  dns_lookup_realm = false
  dns_lookup_kdc   = true
  rdns             = false
EOF

# Register HTTP/<fqdn> on this computer's AD account. Windows asks the DC for
# a ticket to that name, which the DC encrypts with the computer account's
# key. The account is named after the hostname (IP-10-0-0-x); smb.conf's
# netbios name above drops the dashes, so name it explicitly.
MACHINE=$(hostname -s | tr '[:lower:]' '[:upper:]')
net ads setspn add "$MACHINE" "HTTP/$FQDN" -U "$admin_username%$admin_password"
net ads setspn list "$MACHINE" -U "$admin_username%$admin_password" | grep -i "HTTP/$FQDN"

# realm join already wrote that key to /etc/krb5.keytab (as host/...). With no
# acceptor name set, mod_auth_gssapi accepts a ticket for any principal whose
# key is in the keytab, so Apache gets a private copy of it.
install -o www-data -g root -m 0400 /etc/krb5.keytab /etc/apache2/http.keytab

# Self-signed certificate for the host name. Its public half is also served
# over plain HTTP at /cert.pem so the Windows host can trust it at boot.
mkdir -p /etc/apache2/ssl
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout /etc/apache2/ssl/webdav.key -out /etc/apache2/ssl/webdav.crt \
  -subj "/CN=$FQDN" -addext "subjectAltName=DNS:$FQDN"
chmod 600 /etc/apache2/ssl/webdav.key
cp /etc/apache2/ssl/webdav.crt /var/www/html/cert.pem
chmod 644 /var/www/html/cert.pem

# Run Apache in mcloud-users (gid 10001, numeric so it doesn't wait on SSSD)
# with umask 007: files written over WebDAV are owned www-data:mcloud-users
# and group-writable, so SMB users can use them -- Samba's "force group".
sed -i 's/^export APACHE_RUN_GROUP=.*/export APACHE_RUN_GROUP="#10001"/' \
  /etc/apache2/envvars
echo "umask 007" >> /etc/apache2/envvars

# mod_dav's lock database must not live on NFS.
install -d -o www-data -g root -m 0700 /var/lib/apache2/dav

cat > /etc/apache2/sites-available/webdav.conf <<EOF
<VirtualHost *:443>
  ServerName $FQDN

  SSLEngine on
  SSLCertificateFile    /etc/apache2/ssl/webdav.crt
  SSLCertificateKeyFile /etc/apache2/ssl/webdav.key

  DavLockDB /var/lib/apache2/dav/lockdb
  Alias /efs /efs

  # Windows' redirector asks for folders without a trailing slash and won't
  # follow mod_dir's 301 for PROPFIND, PROPPATCH or DELETE; without this,
  # folder deletes and timestamp updates fail.
  BrowserMatch "^Microsoft-WebDAV-MiniRedir" redirect-carefully

  <Directory /efs>
    Dav On
    Options Indexes
    AllowOverride None

    # Apache 2.4.53+ caps request bodies at 1 GiB by default; a larger PUT
    # (any upload over 1 GiB, from any client) gets 413. 0 = no limit.
    LimitRequestBody 0

    # Kerberos (Negotiate) single sign-on for domain-joined clients, plus
    # Basic over TLS checked against the same KDC for everything else.
    AuthType GSSAPI
    AuthName "MCLOUD WebDAV"
    GssapiCredStore keytab:/etc/apache2/http.keytab
    GssapiBasicAuth On
    GssapiSSLonly On
    Require valid-user
  </Directory>

  ErrorLog  /var/log/apache2/webdav-error.log
  CustomLog /var/log/apache2/webdav-access.log combined
</VirtualHost>
EOF

a2enmod ssl dav dav_fs auth_gssapi
a2ensite webdav
systemctl restart apache2

# Sudo + permissions
echo "%linux-admins ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/10-linux-admins
sed -i 's/^\(\s*HOME_MODE\s*\)[0-9]\+/\10700/' /etc/login.defs

su -c "exit" rpatel
su -c "exit" jsmith
su -c "exit" akumar
su -c "exit" edavis

chgrp mcloud-users /efs /efs/data
chmod 770 /efs /efs/data
chmod 700 /home/*

cd /efs
# EFS outlives the instance, so a rebuilt gateway finds the clone already there.
[ -d aws-webdav ] || git clone https://github.com/mamonaco1973/aws-webdav.git
chmod -R 775 aws-webdav
chgrp -R mcloud-users aws-webdav

# validate.sh waits for this marker.
echo "user-data complete: $(date -Is)"
touch /root/userdata.done
