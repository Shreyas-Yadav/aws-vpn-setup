# AWS WireGuard VPN Server

Terraform configuration to deploy a self-hosted WireGuard VPN server on AWS Free Tier (Mumbai region, `ap-south-1`). Automatically provisions a `t2.micro` EC2 instance, installs WireGuard, and generates client configs + QR codes on first boot.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.3.0
- AWS CLI configured with valid credentials (`aws configure`)
- An existing EC2 Key Pair in the `ap-south-1` region
- Your public IP address (find it at https://whatismyip.com)

## Configuration

Edit `terraform.tfvars` before deploying:

```hcl
# Name of your EC2 key pair (AWS Console → EC2 → Key Pairs)
key_pair_name = "your-key-pair-name"

# Your public IP for SSH access — format: x.x.x.x/32
your_home_ip = "1.2.3.4/32"

# Number of client configs to generate (1 per device, max 10)
vpn_client_count = 1
```

| Variable | Description | Default |
|---|---|---|
| `key_pair_name` | Name of existing AWS EC2 key pair | *(required)* |
| `your_home_ip` | Your public IP in CIDR notation for SSH | `0.0.0.0/0` |
| `vpn_client_count` | Number of client configs to generate | `1` |

> **Security note:** Set `your_home_ip` to your actual IP (`x.x.x.x/32`) to restrict SSH access. Leaving it as `0.0.0.0/0` opens SSH to the internet.

## Deploy

```bash
# 1. Initialize Terraform
terraform init

# 2. Preview what will be created
terraform plan

# 3. Deploy (confirm with 'yes' when prompted)
terraform apply
```

After apply completes, Terraform prints your server's public IP and helper commands:

```
vpn_public_ip     = "x.x.x.x"
ssh_command       = "ssh -i ~/.ssh/your-key.pem ubuntu@x.x.x.x"
view_client_config = "sudo cat /etc/wireguard/clients/client1.conf"
show_qr_code      = "sudo qrencode -t ansiutf8 < /etc/wireguard/clients/client1.conf"
wireguard_status  = "sudo wg show"
```

> WireGuard setup runs on first boot. Wait ~2 minutes after `terraform apply` before SSHing in.

## Connect a Device

### Option A — QR Code (iOS / Android)

1. SSH into the server using the `ssh_command` output
2. Run the `show_qr_code` command
3. Scan the QR code in the WireGuard mobile app

### Option B — Config File (Desktop)

1. SSH into the server
2. Run the `view_client_config` command
3. Copy the config to your local machine:
   ```bash
   scp -i ~/.ssh/your-key.pem ubuntu@<vpn_public_ip>:/etc/wireguard/clients/client1.conf ./client1.conf
   ```
4. Import `client1.conf` into the WireGuard desktop app

For multiple devices, repeat with `client2.conf`, `client3.conf`, etc. (up to `vpn_client_count`).

## Verify the VPN is Running

```bash
# SSH in, then:
sudo wg show          # shows active peers and traffic
sudo systemctl status wg-quick@wg0
```

## Tear Down

```bash
terraform destroy
```

This removes all AWS resources (EC2, VPC, EIP, security group). The Elastic IP is only free while the instance is running — destroy when not in use to avoid charges.

## AWS Free Tier Usage

| Resource | Free Tier Limit | This Setup |
|---|---|---|
| EC2 `t2.micro` | 750 hrs/month | 1 instance |
| EBS storage | 30 GB/month | 8 GB |
| Elastic IP | Free while instance runs | 1 EIP |
| Data transfer out | 100 GB/month | Depends on usage |

> Data transfer charges apply beyond 100 GB/month. VPN traffic counts toward this limit.
