# ================================================================================
# FILE: outputs.tf
#
# Purpose:
#   - Exposes the host names and instance IDs that validate.sh and
#     benchmark.sh use to reach the servers over SSM.
# ================================================================================

output "gateway_instance_id" {
  description = "Linux gateway (Samba + WebDAV over EFS)"
  value       = aws_instance.efs_client_instance.id
}

output "gateway_private_dns" {
  description = "Name both shares are served under: \\\\<name>\\efs and https://<name>/efs"
  value       = aws_instance.efs_client_instance.private_dns
}

output "gateway_public_dns" {
  description = "Public DNS name for SSH to the gateway"
  value       = aws_instance.efs_client_instance.public_dns
}

output "windows_instance_id" {
  description = "Windows client"
  value       = aws_instance.windows_ad_instance.id
}

output "windows_public_dns" {
  description = "Public DNS name for RDP to the Windows client"
  value       = aws_instance.windows_ad_instance.public_dns
}
