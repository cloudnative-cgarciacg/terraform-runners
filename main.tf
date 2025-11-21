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

# ---------------------------
# Networking
# ---------------------------

resource "google_compute_network" "runner_vpc" {
  name                    = "github-runner-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "runner_subnet" {
  name                     = "github-runner-subnet"
  ip_cidr_range            = var.vpc_cidr
  region                   = var.region
  network                  = google_compute_network.runner_vpc.id
  private_ip_google_access = true
}

# ---------------------------
# Service accounts
# ---------------------------

resource "google_service_account" "proxy_sa" {
  account_id   = "github-proxy-sa"
  display_name = "Service account para proxy Squid"
}

resource "google_service_account" "runner_sa" {
  account_id   = "github-runner-sa"
  display_name = "Service account para GitHub runner"
}

# ---------------------------
# PROXY VM (Squid)
# ---------------------------

data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

resource "google_compute_instance" "proxy" {
  name         = "github-proxy"
  machine_type = var.proxy_machine_type
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

    # IP pública para que el proxy salga a internet
    access_config {}
  }

  service_account {
    email  = google_service_account.proxy_sa.email
    scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write"
    ]
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    set -euxo pipefail

    apt-get update -y
    apt-get install -y squid

    # Backup config original
    mv /etc/squid/squid.conf /etc/squid/squid.conf.bak || true

    cat << 'EOF' > /etc/squid/squid.conf
    http_port 3128

    # Red interna permitida (ajusta si cambias el CIDR)
    acl localnet src ${var.vpc_cidr}

    # Dominios permitidos (GitHub + ghcr.io)
    acl github_domains dstdomain \
        .github.com \
        .githubusercontent.com \
        github.com \
        ghcr.io

    http_access allow localnet github_domains
    http_access deny all

    # Logs básicos
    access_log stdio:/var/log/squid/access.log
    cache_log stdio:/var/log/squid/cache.log
    EOF

    systemctl restart squid
    systemctl enable squid
  EOT
}

# ---------------------------
# RUNNER VM
# ---------------------------

resource "google_compute_instance" "runner" {
  name         = "github-actions-runner"
  machine_type = var.runner_machine_type
  zone         = var.zone

  tags = ["github-runner"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = 50
      type  = "pd-balanced"
    }
  }

  # Sin IP pública
  network_interface {
    subnetwork = google_compute_subnetwork.runner_subnet.id
    # sin access_config
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

    RUNNER_VERSION="${var.runner_version}"
    GITHUB_URL="${var.github_repo_url}"
    RUNNER_TOKEN="${var.github_registration_token}"
    RUNNER_LABELS="${var.runner_labels}"
    PROXY_IP="${google_compute_instance.proxy.network_interface[0].network_ip}"
    PROXY_PORT="3128"

    # Configurar proxy a nivel de sistema
    echo "HTTP_PROXY=http://$${PROXY_IP}:$${PROXY_PORT}" >> /etc/environment
    echo "HTTPS_PROXY=http://$${PROXY_IP}:$${PROXY_PORT}" >> /etc/environment
    echo "NO_PROXY=169.254.169.254,metadata.google.internal,localhost,127.0.0.1" >> /etc/environment

    export HTTP_PROXY="http://$${PROXY_IP}:$${PROXY_PORT}"
    export HTTPS_PROXY="http://$${PROXY_IP}:$${PROXY_PORT}"
    export NO_PROXY="169.254.169.254,metadata.google.internal,localhost,127.0.0.1"

    apt-get update -y
    apt-get install -y curl tar

    id runner || useradd -m -s /bin/bash runner

    mkdir -p /opt/actions-runner
    chown runner:runner /opt/actions-runner
    cd /opt/actions-runner

    sudo -u runner bash -c "
      set -euxo pipefail

      curl -o actions-runner-linux-x64-${var.runner_version}.tar.gz -L https://github.com/actions/runner/releases/download/v${var.runner_version}/actions-runner-linux-x64-${var.runner_version}.tar.gz
      tar xzf ./actions-runner-linux-x64-${var.runner_version}.tar.gz

      ./config.sh --unattended \\
        --url '${var.github_repo_url}' \\
        --token '${var.github_registration_token}' \\
        --labels '${var.runner_labels}' \\
        --name 'gcp-$${HOSTNAME}' \\
        --work '_work'

      sudo ./svc.sh install
      sudo ./svc.sh start
    "
  EOT
}

# ---------------------------
# FIREWALL RULES
# ---------------------------

# 1) El runner SOLO puede hablar con el proxy en 3128
resource "google_compute_firewall" "runner_to_proxy" {
  name      = "github-runner-egress-to-proxy"
  network   = google_compute_network.runner_vpc.id
  direction = "EGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["3128"]
  }

  destination_ranges = [google_compute_instance.proxy.network_interface[0].network_ip]
  target_tags        = ["github-runner"]

  description = "Permite al runner salir solo hacia el proxy Squid en 3128"
}

# 2) Denegar cualquier otro egress del runner
resource "google_compute_firewall" "runner_egress_deny_all" {
  name      = "github-runner-egress-deny-all"
  network   = google_compute_network.runner_vpc.id
  direction = "EGRESS"
  priority  = 2000

  deny {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["github-runner"]

  description = "Deniega todo el tráfico de salida directo desde el runner"
}

# 3) Permitir que el runner llegue al proxy (ingress)
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

  description = "Permite al runner acceder al proxy Squid en 3128"
}

# 4) Proxy puede salir a internet por 80/443
resource "google_compute_firewall" "proxy_egress_internet" {
  name      = "github-proxy-egress-internet"
  network   = google_compute_network.runner_vpc.id
  direction = "EGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["github-proxy"]

  description = "Permite al proxy salir a internet por 80/443"
}
