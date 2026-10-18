# ================================================================================
# SECURITY GROUPS: Lab Access Rules (RDP / SSH / SMB / WebDAV / ICMP)
# ================================================================================
# Purpose:
#   - Provides connectivity to lab instances for administration and testing.
#   - RDP is used for Windows instance access.
#   - SSH is used for Linux instance access.
#   - SMB/445 is included for AD/Samba testing scenarios.
#   - HTTPS/443 (WebDAV) and HTTP/80 (certificate download) are VPC-only.
#   - ICMP is enabled for basic reachability checks.
#
# Notes:
#   - Ingress is currently open to 0.0.0.0/0 for demo purposes.
#   - Production deployments must restrict ingress to trusted CIDRs or
#     security-group sources.
# ================================================================================

# ================================================================================
# RESOURCE: aws_security_group.ad_rdp_sg
# ================================================================================
# Purpose:
#   - Allows Remote Desktop (TCP/3389) access to Windows instances.
# ================================================================================
resource "aws_security_group" "ad_rdp_sg" {
  name        = "webdav-rdp-security-group"
  description = "Allow RDP access from the internet"
  vpc_id      = data.aws_vpc.ad_vpc.id

  # ------------------------------------------------------------------------------
  # INGRESS: RDP (TCP/3389)
  # ------------------------------------------------------------------------------
  ingress {
    description = "Allow RDP from anywhere (demo only)"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ------------------------------------------------------------------------------
  # INGRESS: ICMP (Ping)
  # ------------------------------------------------------------------------------
  ingress {
    description = "Allow ICMP from anywhere (demo only)"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ------------------------------------------------------------------------------
  # EGRESS: ALL
  # ------------------------------------------------------------------------------
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ================================================================================
# RESOURCE: aws_security_group.ad_ssh_sg
# ================================================================================
# Purpose:
#   - Allows SSH (TCP/22) access to Linux instances.
#   - Allows SMB (TCP/445) for AD/Samba testing scenarios.
#   - Allows WebDAV over HTTPS (TCP/443) and HTTP (TCP/80) from the VPC.
# ================================================================================
resource "aws_security_group" "ad_ssh_sg" {
  name        = "webdav-gateway-security-group"
  description = "Allow SSH access from the internet"
  vpc_id      = data.aws_vpc.ad_vpc.id

  # ------------------------------------------------------------------------------
  # INGRESS: SSH (TCP/22)
  # ------------------------------------------------------------------------------
  ingress {
    description = "Allow SSH from anywhere (demo only)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ------------------------------------------------------------------------------
  # INGRESS: SMB (TCP/445)
  # ------------------------------------------------------------------------------
  ingress {
    description = "Allow SMB from anywhere (demo only)"
    from_port   = 445
    to_port     = 445
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ------------------------------------------------------------------------------
  # INGRESS: WebDAV over HTTPS (TCP/443) - VPC only
  # ------------------------------------------------------------------------------
  ingress {
    description = "Allow WebDAV over HTTPS from inside the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.ad_vpc.cidr_block]
  }

  # ------------------------------------------------------------------------------
  # INGRESS: HTTP (TCP/80) - VPC only
  # ------------------------------------------------------------------------------
  # Serves only the self-signed certificate (/cert.pem) so the Windows host
  # can add it to its trusted roots; WebClient rejects untrusted certificates.
  ingress {
    description = "Allow certificate download from inside the VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.ad_vpc.cidr_block]
  }

  # ------------------------------------------------------------------------------
  # INGRESS: ICMP (Ping)
  # ------------------------------------------------------------------------------
  ingress {
    description = "Allow ICMP from anywhere (demo only)"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ------------------------------------------------------------------------------
  # EGRESS: ALL
  # ------------------------------------------------------------------------------
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
