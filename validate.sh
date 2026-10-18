#!/bin/bash
# ==============================================================================
# validate.sh - SMB + WebDAV over EFS: deployment check
# ------------------------------------------------------------------------------
#   - Waits for the gateway's user data to finish (Samba, Apache, AD join).
#   - Over SSM, on the gateway, signs in as jsmith and checks:
#       SMB (smbclient), WebDAV with Basic and with Kerberos (curl), and that
#       a file written over one protocol reads back over the other.
#   - Shows who owns a file written each way -- the key identity difference.
#   - Prints the RDP/SSH hosts and a login. One line per check.
# ==============================================================================
set -euo pipefail
cd "$(dirname "$0")"
export AWS_DEFAULT_REGION="us-east-1"

fail() { echo "FAILED"; echo "ERROR: $*" >&2; exit 1; }
step() { printf '%-56s' "$1..."; }
ok()   { echo "${1:-ok}"; }

tf_out() { terraform -chdir=02-servers output -raw "$1" 2>/dev/null || true; }

GATEWAY_ID="$(tf_out gateway_instance_id)"
GATEWAY_DNS="$(tf_out gateway_private_dns)"
[ -n "${GATEWAY_ID}" ] || fail "No gateway_instance_id output. Run ./apply.sh first."

# Runs a bash script on an instance over SSM; prints its stdout.
ssm_bash() {
  local instance="$1" script="$2" cmd_id status
  cmd_id="$(aws ssm send-command --instance-ids "${instance}" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"echo $(base64 -w0 <<<"${script}") | base64 -d | bash\"]" \
    --query Command.CommandId --output text)"
  for ((i = 0; i < 60; i++)); do
    sleep 5
    status="$(aws ssm get-command-invocation --command-id "${cmd_id}" \
      --instance-id "${instance}" --query Status --output text 2>/dev/null || true)"
    case "${status}" in Pending|InProgress|Delayed|"") continue ;; *) break ;; esac
  done
  aws ssm get-command-invocation --command-id "${cmd_id}" \
    --instance-id "${instance}" --query StandardOutputContent --output text
}

# ------------------------------------------------------------------------------
# Gateway ready
# ------------------------------------------------------------------------------
step "Gateway setup complete (up to 20 min)"
READY=""
for ((i = 0; i < 80; i++)); do
  PING="$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${GATEWAY_ID}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
  if [ "${PING}" = "Online" ]; then
    READY="$(ssm_bash "${GATEWAY_ID}" 'test -f /root/userdata.done && echo yes; grep -q "^ERROR at line" /root/userdata.log && echo failed' || true)"
    case "${READY}" in *failed*) fail "Gateway user data failed. aws ssm start-session --target ${GATEWAY_ID}, then sudo cat /root/userdata.log" ;; *yes*) break ;; esac
  fi
  sleep 15
done
case "${READY}" in *yes*) ok ;; *) fail "Gateway not ready. aws ssm start-session --target ${GATEWAY_ID}, then sudo cat /root/userdata.log" ;; esac

# ------------------------------------------------------------------------------
# Both protocols, as jsmith, on the gateway
# ------------------------------------------------------------------------------
# The script reads jsmith's password from Secrets Manager on the gateway, so
# it never appears in the SSM command history.
read -r -d '' CHECKS <<'EOF' || true
H="__HOST__"
CA=/etc/apache2/ssl/webdav.crt
URL="https://$H/efs/data"
PW=$(aws secretsmanager get-secret-value --secret-id jsmith_ad_credentials_webdav \
  --query SecretString --output text | jq -r .password)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
printf 'username = jsmith\npassword = %s\ndomain = MCLOUD\n' "$PW" > "$W/auth"
printf 'user = "jsmith:%s"\n' "$PW" > "$W/curlrc"
SMB() { smbclient "//$H/efs" -A "$W/auth" -D data -c "$1" >/dev/null 2>&1; }
DAV() { curl -s --cacert "$CA" -K "$W/curlrc" -w '%{http_code}' "$@"; }

echo "from smb $RANDOM" > "$W/a.txt"; echo "from dav $RANDOM" > "$W/b.txt"

SMB "put $W/a.txt validate-smb.txt" && echo "smb_put ok" || echo "smb_put FAIL"
echo "dav_basic $(DAV -o /dev/null -X PROPFIND -H 'Depth: 1' "$URL/")"
export KRB5CCNAME="FILE:$W/cc"
echo "$PW" | kinit jsmith >/dev/null 2>&1 \
  && echo "dav_kerberos $(curl -s --cacert "$CA" --negotiate -u : -o /dev/null -w '%{http_code}' -X PROPFIND -H 'Depth: 1' "$URL/")" \
  || echo "dav_kerberos kinit-failed"
DAV -o "$W/a.dav" "$URL/validate-smb.txt" >/dev/null
cmp -s "$W/a.txt" "$W/a.dav" && echo "smb_to_dav ok" || echo "smb_to_dav FAIL"
echo "dav_put $(DAV -o /dev/null -T "$W/b.txt" "$URL/validate-dav.txt")"
SMB "get validate-dav.txt $W/b.smb"
cmp -s "$W/b.txt" "$W/b.smb" && echo "dav_to_smb ok" || echo "dav_to_smb FAIL"
echo "owner_smb $(stat -c '%U:%G %a' /efs/data/validate-smb.txt)"
echo "owner_dav $(stat -c '%U:%G %a' /efs/data/validate-dav.txt)"
rm -f /efs/data/validate-smb.txt /efs/data/validate-dav.txt
EOF

OUT="$(ssm_bash "${GATEWAY_ID}" "${CHECKS//__HOST__/${GATEWAY_DNS}}")"
val() { awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' <<<"${OUT}"; }

step "SMB write as jsmith (smbclient)"
[ "$(val smb_put)" = "ok" ] || fail "smbclient could not write to //${GATEWAY_DNS}/efs/data."
ok

step "WebDAV sign-in, Basic over HTTPS"
[ "$(val dav_basic)" = "207" ] || fail "PROPFIND with Basic answered '$(val dav_basic)'. Check /var/log/apache2/webdav-error.log."
ok

step "WebDAV sign-in, Kerberos (HTTP/ service principal)"
[ "$(val dav_kerberos)" = "207" ] || fail "PROPFIND with Negotiate answered '$(val dav_kerberos)'. Check klist -k /etc/apache2/http.keytab."
ok

step "Written over SMB, read over WebDAV"
[ "$(val smb_to_dav)" = "ok" ] || fail "Contents differ or GET failed."
ok

step "Written over WebDAV, read over SMB"
[ "$(val dav_put)" = "201" ] && [ "$(val dav_to_smb)" = "ok" ] || fail "PUT answered '$(val dav_put)', read back '$(val dav_to_smb)'."
ok

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
JSMITH="$(aws secretsmanager get-secret-value --secret-id jsmith_ad_credentials_webdav \
  --query SecretString --output text | jq -r .password)"

cat <<EOF

EFS over SMB and WebDAV
=======================
File owner : SMB    -> $(val owner_smb)  (the signed-in user)
             WebDAV -> $(val owner_dav)  (Apache's account)
Windows    : RDP to $(tf_out windows_public_dns)
             Z: = \\\\${GATEWAY_DNS}\\efs       (SMB)
             W: = \\\\${GATEWAY_DNS}@SSL\\efs   (WebDAV)
             R: = rclone over the same WebDAV URL (as jsmith)
             Needs ~10 minutes after deploy to join the domain.
Linux      : SSH to $(tf_out gateway_public_dns)
Sign in    : MCLOUD\\jsmith / ${JSMITH}
Benchmark  : ./benchmark.sh
EOF
