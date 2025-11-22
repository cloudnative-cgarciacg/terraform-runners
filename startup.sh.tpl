#!/bin/bash
set -euxo pipefail

# Estos ${...} son variables del template de Terraform (minúsculas)
GITHUB_URL="${github_url}"
RUNNER_VERSION="${runner_version}"
RUNNER_LABELS="${runner_labels}"
GITHUB_TOKEN="${github_token}"

apt-get update -y
apt-get install -y curl tar

mkdir -p /opt/actions-runner
cd /opt/actions-runner

# OJO: aquí solo usamos variables Bash ($RUNNER_VERSION), SIN ${...}
curl -Ls -o actions-runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz"

tar xzf actions-runner.tar.gz

# Necesario para correr como root en GCE
export RUNNER_ALLOW_RUNASROOT=1

./config.sh --unattended \
  --url "$GITHUB_URL" \
  --token "$GITHUB_TOKEN" \
  --labels "$RUNNER_LABELS" \
  --name "gcp-$(hostname)" \
  --work "_work"

./svc.sh install
./svc.sh start
