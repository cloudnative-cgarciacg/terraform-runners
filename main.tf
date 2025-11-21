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

# -----------------------------
# Networking
# -----------------------------

resource "google_compute_network" "vpc" {
  name                    = "github-runner-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name                     = "github-runner-subnet"
  ip_cidr_range            = var.network_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}

# Cloud Router + NAT para salida a internet SIN IP pública en la VM
resource "google_compute_router" "router" {
  name    = "github-runner-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "github-runner-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.subnet.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# -----------------------------
# Service Account
# -----------------------------

resource "google_service_account" "runner_sa" {
  account_id   = "github-runner-sa"
  display_name = "Service account for GitHub Actions runner"
}

# -----------------------------
# VM para el runner
# -----------------------------

data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}

resource "google_compute_instance" "runner" {
  name         = "github-actions-runner"
  machine_type = var.runner_machine_type
  zone         = var.zone

  tags = ["github-runner"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = 30
      type  = "pd-balanced"
    }
  }

  # Sin IP pública
  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
  }

  service_account {
    email  = google_service_account.runner_sa.email
    scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write"
    ]
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    set -euxo pipefail

    # Log del startup para debug
    exec > /var/log/github-runner-startup.log 2>&1

    RUNNER_VERSION="${var.runner_version}"
    GITHUB_URL="${var.github_url}"
    REG_TOKEN="${var.github_token}"
    RUNNER_LABELS="${var.runner_labels}"

    # 1. Instalar dependencias
    apt-get update -y
    apt-get install -y curl tar ca-certificates

    # 2. Descargar el runner en /opt/actions-runner
    mkdir -p /opt/actions-runner
    cd /opt/actions-runner

    curl -Ls -o actions-runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${var.runner_version}/actions-runner-linux-x64-${var.runner_version}.tar.gz"

    tar xzf actions-runner.tar.gz

    # 3. Configurar el runner en modo no interactivo
    ./config.sh --unattended \
      --url "${GITHUB_URL}" \
      --token "${REG_TOKEN}" \
      --labels "${RUNNER_LABELS}" \
      --name "gcp-$(hostname)" \
      --work "_work"

    # 4. Instalar y arrancar el servicio
    ./svc.sh install
    ./svc.sh start
  EOT
}

# -----------------------------
# Firewall rules
# -----------------------------

# SSH vía IAP (opcional pero útil)
resource "google_compute_firewall" "iap_ssh" {
  name      = "github-runner-iap-ssh"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["github-runner"]
  description   = "Allow SSH over IAP to runner VM"
}

# Permitir solo EGRESO TCP 443 desde el runner
resource "google_compute_firewall" "runner_allow_https" {
  name      = "github-runner-allow-https"
  network   = google_compute_network.vpc.id
  direction = "EGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["github-runner"]
  description        = "Allow runner to access internet only over HTTPS"
}

# Denegar TODO el resto de egreso desde el runner
resource "google_compute_firewall" "runner_deny_all_egress" {
  name      = "github-runner-deny-all-egress"
  network   = google_compute_network.vpc.id
  direction = "EGRESS"
  priority  = 2000

  deny {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["github-runner"]
  description        = "Deny any other egress traffic from runner"
}
