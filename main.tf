terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# -----------------------------------------------------------------------------
# Networking
#
# Creates a VPC and private subnet for the GitHub Actions runner.  A Cloud NAT
# gateway is provisioned so the runner can initiate outbound connections over
# HTTPS without having a public IP.  Egress from the runner is restricted to
# TCP port 443 using a firewall rule.  All other outbound traffic is denied.
# -----------------------------------------------------------------------------

resource "google_compute_network" "runner_vpc" {
  name                    = "github-runner-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "runner_subnet" {
  name                     = "github-runner-subnet"
  ip_cidr_range            = var.network_cidr
  region                   = var.region
  network                  = google_compute_network.runner_vpc.id
  private_ip_google_access = true
}

# Router to enable Cloud NAT
resource "google_compute_router" "runner_router" {
  name    = "github-runner-router"
  region  = var.region
  network = google_compute_network.runner_vpc.id
}

# Cloud NAT to provide internet access to private instances without an
# external IP address.
resource "google_compute_router_nat" "runner_nat" {
  name                               = "github-runner-nat"
  router                             = google_compute_router.runner_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.runner_subnet.name
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# Firewall rule allowing outbound HTTPS only for the runner.  The runner
# instances are tagged with "github-runner" so that the rule applies only
# to them.  Outbound traffic on TCP port 443 is permitted to any destination.
resource "google_compute_firewall" "runner_https_egress" {
  name      = "github-runner-egress-https"
  network   = google_compute_network.runner_vpc.id
  direction = "EGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["github-runner"]
  description        = "Allow runner to egress only on TCP port 443"
}

# Catch‑all deny rule to prevent any other outbound traffic from the runner.
resource "google_compute_firewall" "runner_deny_egress" {
  name      = "github-runner-deny-egress"
  network   = google_compute_network.runner_vpc.id
  direction = "EGRESS"
  priority  = 2000

  deny {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["github-runner"]
  description        = "Deny all other egress traffic from the runner"
}

# Optional firewall rule to allow SSH access to the runner via IAP.  This rule
# allows TCP port 22 from the IAP forward proxy range (35.235.240.0/20).  If you
# do not need SSH access, you can comment this out.
resource "google_compute_firewall" "iap_ssh" {
  name      = "github-runner-iap-ssh"
  network   = google_compute_network.runner_vpc.id
  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["github-runner"]
  description   = "Allow SSH via IAP to the runner for debugging"
}

# -----------------------------------------------------------------------------
# Service Account
#
# A dedicated service account for the runner VM.  Minimal scopes are
# sufficient to write logs and monitoring metrics.  Additional scopes can be
# added if the runner requires access to GCP services.
# -----------------------------------------------------------------------------

resource "google_service_account" "runner_sa" {
  account_id   = "github-runner-sa"
  display_name = "Service account for GitHub Actions runner"
}

# -----------------------------------------------------------------------------
# Compute Instance for the Runner
#
# Creates a VM without a public IP.  The startup script installs the GitHub
# Actions runner and registers it against the organisation or repository
# specified by var.github_repo_url.  The runner uses the provided token to
# register and will automatically start on boot.
# -----------------------------------------------------------------------------

data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}

resource "google_compute_instance" "runner" {
  name         = "github-actions-runner"
  machine_type = var.machine_type
  zone         = var.zone

  tags = ["github-runner"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = 50
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.runner_subnet.id
    # No public IP assigned
  }

  service_account {
    email  = google_service_account.runner_sa.email
    scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
    ]
  }

  metadata_startup_script = <<EOF
#!/bin/bash
set -euxo pipefail

# This script installs and registers the GitHub Actions runner.  The base
# Ubuntu 22.04 image includes curl and tar.  If they are missing you may
# need to preinstall them in a custom image or allow outbound HTTP
# temporarily for apt-get install.

mkdir -p /opt/actions-runner
cd /opt/actions-runner

RUNNER_VERSION="${var.runner_version}"

curl -Ls -o actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
  https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz
tar xzf actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz

# Configure the runner (unattended) using the provided registration token
./config.sh --unattended \
  --url "${var.github_repo_url}" \
  --token "${var.github_token}" \
  --labels "${var.runner_labels}" \
  --name "gcp-${HOSTNAME}" \
  --work "_work"

# Install and start the runner as a system service
./svc.sh install
./svc.sh start
EOF
}