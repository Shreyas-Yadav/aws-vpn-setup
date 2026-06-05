# =============================================================
# GCP WireGuard VPN — Fill in your values here
# =============================================================

# Your GCP project ID (find it in the GCP Console dashboard)
project_id = "<project_name>"

# Region and zone.
# ⚠️  Free tier (e2-micro) is only available in us-central1 and us-east1.
#     asia-south1 (Mumbai) incurs normal compute charges (~$6/month for e2-micro).
region = "asia-south1"
zone   = "asia-south1-a"

# Your home public IP for SSH access — find it at https://whatismyip.com
# Format must be x.x.x.x/32
your_home_ip = "0.0.0.0/32"

# Linux user to SSH as. "ubuntu" is correct for Ubuntu 22.04 images on GCP.
ssh_user = "ubuntu"

# Paste the contents of your SSH public key (e.g. cat ~/.ssh/id_rsa.pub)
ssh_public_key = "ssh-ed25519 AAAA...."

# Number of VPN client configs to generate (1 per device, max 10)
vpn_client_count = 2
