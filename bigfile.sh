#!/bin/bash
# ==============================================================================
# bigfile.sh - Run bigfile.ps1 on the Windows client, then verify on the gateway
# ------------------------------------------------------------------------------
#   Sends bigfile.ps1 over SSM (about 10 minutes for 5 GB), then checks each
#   copy's size and SHA-256 on the gateway against the source, prints a
#   summary and removes the test files. Extra arguments go to bigfile.ps1,
#   e.g. ./bigfile.sh -SizeGB 6
# ==============================================================================
set -euo pipefail
cd "$(dirname "$0")"
export AWS_DEFAULT_REGION="us-east-1"

tf_out() { terraform -chdir=02-servers output -raw "$1" 2>/dev/null || true; }
WINDOWS_ID="$(tf_out windows_instance_id)"
GATEWAY_ID="$(tf_out gateway_instance_id)"
GATEWAY_DNS="$(tf_out gateway_private_dns)"
[ -n "${WINDOWS_ID}" ] || { echo "ERROR: No windows_instance_id output. Run ./apply.sh first." >&2; exit 1; }

# Runs a command document on an instance and prints its stdout when done.
ssm_run() {
  local instance="$1" document="$2" params="$3" cmd_id status
  cmd_id="$(aws ssm send-command --instance-ids "${instance}" --document-name "${document}" \
    --parameters "${params}" --query Command.CommandId --output text)"
  while :; do
    sleep 10
    status="$(aws ssm get-command-invocation --command-id "${cmd_id}" \
      --instance-id "${instance}" --query Status --output text 2>/dev/null || true)"
    case "${status}" in Pending|InProgress|Delayed|"") continue ;; *) break ;; esac
  done
  aws ssm get-command-invocation --command-id "${cmd_id}" --instance-id "${instance}" \
    --query StandardOutputContent --output text
  [ "${status}" = "Success" ] || { echo "ERROR: SSM command ended with ${status}." >&2; return 1; }
}

echo "NOTE: Writing a large file through Z:, W: and R: on ${WINDOWS_ID}..."
PARAMS="$(jq -n --rawfile s bigfile.ps1 --arg server "${GATEWAY_DNS}" --arg extra "$*" \
  --arg q "'" \
  '{commands: ["& {\n" + $s + "\n} -Server " + $q + $server + $q + " " + $extra],
    executionTimeout: ["3600"]}')"
WIN_OUT="$(ssm_run "${WINDOWS_ID}" AWS-RunPowerShellScript "${PARAMS}")"

echo "NOTE: Checking the copies on the gateway..."
GW_OUT="$(ssm_run "${GATEWAY_ID}" AWS-RunShellScript \
  '{"commands":["cd /efs/data/bigfile && for f in smb.bin dav.bin rcl.bin; do if [ -f $f ]; then echo \"check $f $(stat -c %s $f) $(sha256sum $f | cut -d\" \" -f1)\"; else echo \"check $f missing\"; fi; done; rm -rf /efs/data/bigfile"],"executionTimeout":["3600"]}')"

# PowerShell output arrives with CRLF line endings: strip the CR, or it sticks
# to the last field and no checksum ever matches.
WIN_OUT="$(tr -d '\r' <<<"${WIN_OUT}")"
GW_OUT="$(tr -d '\r' <<<"${GW_OUT}")"
SRC="$(awk '$1 == "source_sha256" { print tolower($2) }' <<<"${WIN_OUT}")"
echo
echo "source sha256: ${SRC}"
echo "${WIN_OUT}" | grep -E '^(write|read10mb) '
echo "${GW_OUT}" | grep '^check ' | while read -r _ file size sum; do
  if [ "${size}" = "missing" ]; then
    echo "server ${file}: not on the server"
  elif [ "${sum}" = "${SRC}" ]; then
    echo "server ${file}: ${size} bytes, SHA-256 matches the source"
  else
    echo "server ${file}: ${size} bytes, SHA-256 ${sum} DOES NOT match (partial or corrupt)"
  fi
done
