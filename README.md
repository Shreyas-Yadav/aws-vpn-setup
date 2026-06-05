# WireGuard VPN Server — AWS & GCP

Terraform configurations to deploy a self-hosted WireGuard VPN server on either **AWS** or **GCP**. Pick a provider by entering its directory. Both setups automatically install WireGuard and generate client configs + QR codes on first boot.

```
aws-vpn-setup/
  aws/   ← deploy on AWS (ap-south-1, t2.micro, free tier eligible)
  gcp/   ← deploy on GCP (asia-south1, e2-micro)
```

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.3.0

**AWS:**
- AWS CLI configured (`aws configure`)
- An existing EC2 Key Pair in `ap-south-1`

**GCP:**
- `gcloud` CLI installed and authenticated:
  ```bash
  gcloud auth application-default login
  ```
- A GCP project with Compute Engine API enabled:
  ```bash
  gcloud services enable compute.googleapis.com --project=YOUR_PROJECT_ID
  ```
- Your SSH public key (e.g. `~/.ssh/id_rsa.pub`)

---

## Deploy on AWS

```bash
cd aws/

# Edit terraform.tfvars with your key pair name and home IP
terraform init
terraform plan
terraform apply
```

**`aws/terraform.tfvars` variables:**

| Variable | Description | Default |
|---|---|---|
| `key_pair_name` | Name of existing AWS EC2 key pair | *(required)* |
| `your_home_ip` | Your public IP in CIDR notation for SSH | `0.0.0.0/0` |
| `vpn_client_count` | Number of client configs to generate | `1` |

**SSH command** (from Terraform output):
```bash
ssh -i ~/.ssh/your-key.pem ubuntu@<vpn_public_ip>
```

---

## Deploy on GCP

```bash
cd gcp/

# Edit terraform.tfvars with your project ID, home IP, and SSH public key
terraform init
terraform plan
terraform apply
```

**`gcp/terraform.tfvars` variables:**

| Variable | Description | Default |
|---|---|---|
| `project_id` | Your GCP project ID | *(required)* |
| `region` | GCP region | `asia-south1` |
| `zone` | GCP zone | `asia-south1-a` |
| `your_home_ip` | Your public IP in CIDR notation for SSH | `0.0.0.0/0` |
| `ssh_user` | Linux username to SSH as | `ubuntu` |
| `ssh_public_key` | Contents of your public key file | *(required)* |
| `vpn_client_count` | Number of client configs to generate | `1` |

> **GCP free tier note:** The e2-micro free tier only applies in `us-central1` and `us-east1`. Using `asia-south1` (Mumbai) incurs normal compute charges (~$6/month).

**SSH command** (from Terraform output):
```bash
ssh ubuntu@<vpn_public_ip>
```

---

## Connect a Device

After `terraform apply`, wait ~2 minutes for WireGuard to finish installing, then SSH in.

### Option A — QR Code (iOS / Android)
```bash
sudo qrencode -t ansiutf8 < /etc/wireguard/clients/client1.conf
```
Scan in the WireGuard mobile app.

### Option B — Config File (Mac laptop)

The client config is owned by root on the server, so copy it to your home directory first, then scp it down:

```bash
# On the server
sudo cp /etc/wireguard/clients/client1.conf ~/client1.conf
sudo chown ubuntu:ubuntu ~/client1.conf

# On your local machine
scp -i /path/to/your-private-key ubuntu@<vpn_public_ip>:~/client1.conf ./client1.conf
```

Install WireGuard tools:
```bash
brew install wireguard-tools
```

Connect:
```bash
# macOS ships bash 3 but wg-quick requires bash 4+ — use Homebrew's bash explicitly
sudo /opt/homebrew/bin/bash $(which wg-quick) up ./client1.conf
```

Disconnect:
```bash
sudo /opt/homebrew/bin/bash $(which wg-quick) down ./client1.conf
```

Verify you're on the VPN (should show the server's public IP):
```bash
curl ifconfig.me
```

For multiple devices use `client2.conf`, `client3.conf`, etc.

## Verify the VPN is Running

```bash
sudo wg show
sudo systemctl status wg-quick@wg0
```

## Tear Down

```bash
# From whichever directory you deployed from:
terraform destroy
```

---

## Security Note

Set `your_home_ip` to your actual IP (`x.x.x.x/32`) to restrict SSH access. Leaving it as `0.0.0.0/0` opens SSH to the internet.

## AWS Free Tier Usage

| Resource | Free Tier Limit | This Setup |
|---|---|---|
| EC2 `t2.micro` | 750 hrs/month | 1 instance |
| EBS storage | 30 GB/month | 8 GB |
| Elastic IP | Free while instance runs | 1 EIP |
| Data transfer out | 100 GB/month | Depends on usage |
