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

  metadata_startup_script = templatefile("${path.module}/startup.sh.tpl", {
  github_url     = var.github_url
  github_token   = var.github_token
  runner_version = var.runner_version
  runner_labels  = var.runner_labels
  })


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
