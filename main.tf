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
# Removed: runner_https_egress rule.  Egress control is now enforced via
# runner_to_proxy and proxy firewall rules.

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

# Allow the runner to connect only to the proxy on port 3128.  This rule
# ensures that all outbound traffic from the runner goes through Squid where
# domain filtering is enforced.
resource "google_compute_firewall" "runner_to_proxy" {
  name      = "github-runner-to-proxy"
  network   = google_compute_network.runner_vpc.id
  direction = "EGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["3128"]
  }

  destination_ranges = [google_compute_instance.proxy.network_interface[0].network_ip]
  target_tags        = ["github-runner"]
  description        = "Allow runner to send traffic to the proxy on port 3128"
}

# Permit the proxy to receive traffic from the runner on port 3128.
resource "google_compute_firewall" "proxy_ingress_from_runner" {
  name      = "github-proxy-ingress-from-runner"
  network   = google_compute_network.runner_vpc.id
  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["3128"]
  }

  source_tags = ["github-runner"]
  target_tags = ["github-proxy"]
  description = "Allow proxy to accept connections from runners on port 3128"
}

# Allow the proxy to access the internet over HTTP/HTTPS.  The proxy uses
# these ports to download packages and forward runner traffic.  You may
# tighten the ports list (for example, to only 443) once package installation
# is no longer needed.
resource "google_compute_firewall" "proxy_egress" {
  name      = "github-proxy-egress"
  network   = google_compute_network.runner_vpc.id
  direction = "EGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["github-proxy"]
  description        = "Allow proxy outbound HTTP and HTTPS"
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

# Service account for the proxy VM.  The proxy forwards outbound requests on
# behalf of the runner and does not need broad permissions.
resource "google_service_account" "proxy_sa" {
  account_id   = "github-proxy-sa"
  display_name = "Service account for Squid proxy"
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

## This script installs and registers the GitHub Actions runner.  The base
## Ubuntu 22.04 image includes curl and tar.  If they are missing you may
## need to preinstall them in a custom image or allow outbound HTTP
## temporarily for apt-get install.

# Configure proxy environment variables so all outbound traffic uses the
# Squid proxy.  This ensures that traffic is filtered to the allowed GitHub
# domains.  NO_PROXY excludes metadata endpoints.
PROXY_IP="${google_compute_instance.proxy.network_interface[0].network_ip}"
PROXY_PORT="3128"
echo "HTTP_PROXY=http://$${PROXY_IP}:$${PROXY_PORT}" >> /etc/environment
echo "HTTPS_PROXY=http://$${PROXY_IP}:$${PROXY_PORT}" >> /etc/environment
echo "NO_PROXY=169.254.169.254,metadata.google.internal,localhost,127.0.0.1" >> /etc/environment
export HTTP_PROXY="http://$${PROXY_IP}:$${PROXY_PORT}"
export HTTPS_PROXY="http://$${PROXY_IP}:$${PROXY_PORT}"
export NO_PROXY="169.254.169.254,metadata.google.internal,localhost,127.0.0.1"

mkdir -p /opt/actions-runner
cd /opt/actions-runner

# Download and unpack the runner using the version from Terraform variables.
curl -Ls -o actions-runner-linux-x64-${var.runner_version}.tar.gz \
  https://github.com/actions/runner/releases/download/v${var.runner_version}/actions-runner-linux-x64-${var.runner_version}.tar.gz
tar xzf actions-runner-linux-x64-${var.runner_version}.tar.gz

# Configure the runner (unattended) using the provided registration token
./config.sh --unattended \
  --url "${var.github_repo_url}" \
  --token "${var.github_token}" \
  --labels "${var.runner_labels}" \
  --name "gcp-$${HOSTNAME}" \
  --work "_work"

# Install and start the runner as a system service
./svc.sh install
./svc.sh start
EOF
}

# -----------------------------------------------------------------------------
# Compute Instance for the Squid Proxy
#
# This VM has a public IP so it can forward traffic to the internet on behalf
# of the runner.  Squid is configured to only allow traffic to a limited set of
# GitHub domains over HTTPS.  Runner VMs send their traffic to the proxy via
# port 3128.
# -----------------------------------------------------------------------------

resource "google_compute_instance" "proxy" {
  name         = "github-proxy"
  machine_type = "e2-small"
  zone         = var.zone

  tags = ["github-proxy"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.runner_subnet.id
    # Assign a public IP so the proxy can reach the internet
    access_config {}
  }

  service_account {
    email  = google_service_account.proxy_sa.email
    scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
    ]
  }

  metadata_startup_script = <<EOF
#!/bin/bash
set -eux

apt-get update -y
apt-get install -y squid

cat >/etc/squid/squid.conf <<EOT
http_port 3128

acl localnet src ${var.network_cidr}

# Allow only the domains required by GitHub Actions self‑hosted runners.  Wildcards
# (e.g., .github.com) allow any subdomain.  These domains are based on the
# official GitHub documentation.  You can add more domains if your workflows
# need additional services.
acl github_domains dstdomain \
    github.com \
    api.github.com \
    codeload.github.com \
    ghcr.io \
    .github.com \
    .githubusercontent.com \
    results-receiver.actions.githubusercontent.com \
    .blob.core.windows.net \
    objects.githubusercontent.com \
    objects-origin.githubusercontent.com \
    github-releases.githubusercontent.com \
    github-registry-files.githubusercontent.com \
    .actions.githubusercontent.com \
    .pkg.github.com \
    pkg-containers.githubusercontent.com \
    github-cloud.githubusercontent.com \
    github-cloud.s3.amazonaws.com \
    dependabot-actions.githubapp.com \
    release-assets.githubusercontent.com \
    api.snapcraft.io

http_access allow localnet github_domains
http_access deny all

access_log stdio:/var/log/squid/access.log
cache_log stdio:/var/log/squid/cache.log
EOT

systemctl restart squid
systemctl enable squid
EOF
}