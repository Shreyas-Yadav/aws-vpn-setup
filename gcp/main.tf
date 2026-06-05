# =============================================================
# WireGuard VPN Server on GCP — Mumbai (asia-south1)
# =============================================================

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3.0"
}

# -------------------------------------------------------------
# Variables
# -------------------------------------------------------------

variable "project_id" {
  description = "Your GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region. NOTE: free tier (e2-micro) only applies in us-central1 / us-east1"
  type        = string
  default     = "asia-south1" # Mumbai
}

variable "zone" {
  description = "GCP zone within the region"
  type        = string
  default     = "asia-south1-a"
}

variable "your_home_ip" {
  description = "Your home public IP for SSH access. Format: x.x.x.x/32"
  type        = string
  default     = "0.0.0.0/0" # ⚠️ Replace with your IP for security
}

variable "ssh_user" {
  description = "Linux username to SSH as (matches the key injected below)"
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key" {
  description = "Contents of your SSH public key file (e.g. ~/.ssh/id_rsa.pub)"
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

provider "google" {
  project = var.project_id
  region  = var.region
}

# -------------------------------------------------------------
# Startup script — installs WireGuard on first boot
# -------------------------------------------------------------

locals {
  startup_script = <<-EOF
    SERVER_EIP="${google_compute_address.vpn_ip.address}"
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

    echo "WireGuard setup complete!" >> /var/log/wireguard-setup.log
  EOF
}

# -------------------------------------------------------------
# VPC Network & Subnet
# -------------------------------------------------------------

resource "google_compute_network" "vpn_vpc" {
  name                    = "wireguard-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "public" {
  name          = "wireguard-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.vpn_vpc.id
}

# -------------------------------------------------------------
# Firewall Rules
# -------------------------------------------------------------

resource "google_compute_firewall" "allow_wireguard" {
  name    = "wireguard-allow-vpn"
  network = google_compute_network.vpn_vpc.name

  allow {
    protocol = "udp"
    ports    = ["51820"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["wireguard"]
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "wireguard-allow-ssh"
  network = google_compute_network.vpn_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [var.your_home_ip]
  target_tags   = ["wireguard"]
}

# -------------------------------------------------------------
# Static External IP
# -------------------------------------------------------------

resource "google_compute_address" "vpn_ip" {
  name   = "wireguard-ip"
  region = var.region
}

# -------------------------------------------------------------
# Compute Instance — e2-micro
# (Free tier eligible in us-central1 / us-east1 only)
# -------------------------------------------------------------

resource "google_compute_instance" "vpn_server" {
  name         = "wireguard-vpn-server"
  machine_type = "e2-micro"
  zone         = var.zone
  tags         = ["wireguard"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 10
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.public.id

    access_config {
      nat_ip = google_compute_address.vpn_ip.address
    }
  }

  metadata = {
    ssh-keys       = "${var.ssh_user}:${var.ssh_public_key}"
    startup-script = local.startup_script
  }
}

# -------------------------------------------------------------
# Outputs
# -------------------------------------------------------------

output "vpn_public_ip" {
  description = "Static public IP of your VPN server"
  value       = google_compute_address.vpn_ip.address
}

output "ssh_command" {
  description = "SSH into your VPN server"
  value       = "ssh ${var.ssh_user}@${google_compute_address.vpn_ip.address}"
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
