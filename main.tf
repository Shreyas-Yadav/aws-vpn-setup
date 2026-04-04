# =============================================================
# WireGuard VPN Server on AWS Free Tier — Mumbai (ap-south-1)
# =============================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3.0"
}

# -------------------------------------------------------------
# Variables
# -------------------------------------------------------------

variable "your_home_ip" {
  description = "Your home public IP (for SSH access). Format: x.x.x.x/32"
  type        = string
  default     = "0.0.0.0/0" # ⚠️ Replace with your IP for security
}

variable "key_pair_name" {
  description = "Name of your existing AWS EC2 key pair for SSH access"
  type        = string
}

variable "vpn_client_count" {
  description = "Number of VPN client configs to generate (1–10)"
  type        = number
  default     = 1
}

# -------------------------------------------------------------
# Provider
# -------------------------------------------------------------

provider "aws" {
  region = "ap-south-1" # Mumbai — closest India region
}

# -------------------------------------------------------------
# Data — Latest Ubuntu 22.04 LTS AMI (Free Tier eligible)
# -------------------------------------------------------------

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -------------------------------------------------------------
# VPC & Networking
# -------------------------------------------------------------

resource "aws_vpc" "vpn_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "wireguard-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpn_vpc.id
  tags   = { Name = "wireguard-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.vpn_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-south-1a"
  map_public_ip_on_launch = true

  tags = { Name = "wireguard-public-subnet" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.vpn_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "wireguard-rt" }
}

resource "aws_route_table_association" "public_rta" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

# -------------------------------------------------------------
# Security Group
# -------------------------------------------------------------

resource "aws_security_group" "vpn_sg" {
  name        = "wireguard-sg"
  description = "Allow WireGuard UDP and SSH"
  vpc_id      = aws_vpc.vpn_vpc.id

  # WireGuard — open to all (clients connect from anywhere)
  ingress {
    description = "WireGuard VPN"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH — restricted to your IP only
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.your_home_ip]
  }

  # Allow all outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "wireguard-sg" }
}

# -------------------------------------------------------------
# Elastic IP — Static public IP (free while instance is running)
# -------------------------------------------------------------

resource "aws_eip" "vpn_eip" {
  domain   = "vpc"
  instance = aws_instance.vpn_server.id

  tags = { Name = "wireguard-eip" }
}

# -------------------------------------------------------------
# User Data — Auto-installs WireGuard on first boot
# -------------------------------------------------------------

locals {
  user_data = <<-EOF
    #!/bin/bash
    set -e

    # Update system
    apt-get update -y
    apt-get upgrade -y

    # Install WireGuard and tools
    apt-get install -y wireguard qrencode iptables

    # Enable IP forwarding
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p

    # Generate server keys
    wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
    chmod 600 /etc/wireguard/server_private.key

    SERVER_PRIVATE=$(cat /etc/wireguard/server_private.key)
    SERVER_PUBLIC=$(cat /etc/wireguard/server_public.key)

    # Get the primary network interface name
    IFACE=$(ip route | grep default | awk '{print $5}' | head -1)

    # Write server config
    cat > /etc/wireguard/wg0.conf <<WGCONF
    [Interface]
    Address = 10.8.0.1/24
    ListenPort = 51820
    PrivateKey = $SERVER_PRIVATE
    PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
    PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $IFACE -j MASQUERADE
    WGCONF

    # Generate client configs
    CLIENT_COUNT=${var.vpn_client_count}
    mkdir -p /etc/wireguard/clients

    for i in $(seq 1 $CLIENT_COUNT); do
      CLIENT_IP="10.8.0.$((i + 1))"
      wg genkey | tee /etc/wireguard/clients/client$i.key | wg pubkey > /etc/wireguard/clients/client$i.pub
      chmod 600 /etc/wireguard/clients/client$i.key

      CLIENT_PRIVATE=$(cat /etc/wireguard/clients/client$i.key)
      CLIENT_PUBLIC=$(cat /etc/wireguard/clients/client$i.pub)

      # Add peer to server config
      cat >> /etc/wireguard/wg0.conf <<PEER

    [Peer]
    PublicKey = $CLIENT_PUBLIC
    AllowedIPs = $CLIENT_IP/32
    PEER

      # Write client config — SERVER_IP filled in at runtime
      SERVER_EIP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
      cat > /etc/wireguard/clients/client$i.conf <<CLIENT
    [Interface]
    PrivateKey = $CLIENT_PRIVATE
    Address = $CLIENT_IP/24
    DNS = 1.1.1.1, 8.8.8.8

    [Peer]
    PublicKey = $SERVER_PUBLIC
    Endpoint = $SERVER_EIP:51820
    AllowedIPs = 0.0.0.0/0
    PersistentKeepalive = 25
    CLIENT

      # Generate QR code for each client
      qrencode -t png -o /etc/wireguard/clients/client$i.png < /etc/wireguard/clients/client$i.conf
    done

    # Start and enable WireGuard
    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0

    echo "✅ WireGuard setup complete!" >> /var/log/wireguard-setup.log
  EOF
}

# -------------------------------------------------------------
# EC2 Instance — Free Tier (t2.micro)
# -------------------------------------------------------------

resource "aws_instance" "vpn_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro" # Free tier eligible
  subnet_id              = aws_subnet.public.id
  key_name               = var.key_pair_name
  vpc_security_group_ids = [aws_security_group.vpn_sg.id]

  root_block_device {
    volume_type           = "gp2"
    volume_size           = 8 # GB — well within 30 GB free tier limit
    delete_on_termination = true
  }

  user_data = local.user_data

  tags = { Name = "wireguard-vpn-server" }
}

# -------------------------------------------------------------
# Outputs
# -------------------------------------------------------------

output "vpn_public_ip" {
  description = "Static public IP of your VPN server"
  value       = aws_eip.vpn_eip.public_ip
}

output "ssh_command" {
  description = "SSH into your VPN server"
  value       = "ssh -i ~/.ssh/${var.key_pair_name}.pem ubuntu@${aws_eip.vpn_eip.public_ip}"
}

output "view_client_config" {
  description = "View client config on server (run after SSH)"
  value       = "sudo cat /etc/wireguard/clients/client1.conf"
}

output "show_qr_code" {
  description = "Show QR code in terminal (run after SSH)"
  value       = "sudo qrencode -t ansiutf8 < /etc/wireguard/clients/client1.conf"
}

output "wireguard_status" {
  description = "Check WireGuard status on server"
  value       = "sudo wg show"
}
