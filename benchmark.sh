#!/bin/bash
# ==============================================================================
# benchmark.sh - Run benchmark.ps1 on the Windows client over SSM
# ------------------------------------------------------------------------------
#   Sends benchmark.ps1 to the Windows host with AWS-RunPowerShellScript,
#   waits for it (about 45-50 minutes with the defaults), and prints its
#   results table.
#   Extra arguments go to benchmark.ps1, e.g. ./benchmark.sh -Runs 1 -LargeMB 256
# ==============================================================================
set -euo pipefail
cd "$(dirname "$0")"
export AWS_DEFAULT_REGION="us-east-1"

WINDOWS_ID="$(terraform -chdir=02-servers output -raw windows_instance_id 2>/dev/null || true)"
GATEWAY_DNS="$(terraform -chdir=02-servers output -raw gateway_private_dns 2>/dev/null || true)"
[ -n "${WINDOWS_ID}" ] || { echo "ERROR: No windows_instance_id output. Run ./apply.sh first." >&2; exit 1; }

PING="$(aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=${WINDOWS_ID}" \
  --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
[ "${PING}" = "Online" ] || { echo "ERROR: Windows host is not online in SSM (${PING}). It may still be joining the domain." >&2; exit 1; }

# Wrapping the script in & { ... } lets its param() block take arguments.
PARAMS="$(jq -n --rawfile s benchmark.ps1 --arg server "${GATEWAY_DNS}" --arg extra "$*" \
  --arg q "'" \
  '{commands: ["& {\n" + $s + "\n} -Server " + $q + $server + $q + " " + $extra],
    executionTimeout: ["10800"]}')"

CMD_ID="$(aws ssm send-command --instance-ids "${WINDOWS_ID}" \
  --document-name AWS-RunPowerShellScript --parameters "${PARAMS}" \
  --comment "SMB vs WebDAV benchmark" --query Command.CommandId --output text)"
echo "NOTE: Benchmark running on ${WINDOWS_ID} (SSM command ${CMD_ID})..."

STATUS=""
while :; do
  sleep 15
  STATUS="$(aws ssm get-command-invocation --command-id "${CMD_ID}" \
    --instance-id "${WINDOWS_ID}" --query Status --output text 2>/dev/null || true)"
  case "${STATUS}" in Pending|InProgress|Delayed|"") continue ;; *) break ;; esac
done

aws ssm get-command-invocation --command-id "${CMD_ID}" --instance-id "${WINDOWS_ID}" \
  --query '[StandardOutputContent, StandardErrorContent]' --output text
[ "${STATUS}" = "Success" ] || { echo "ERROR: Benchmark ended with status ${STATUS}." >&2; exit 1; }
