#!/bin/bash
set -euxo pipefail

GITHUB_URL="${github_url}"
RUNNER_VERSION="${runner_version}"
RUNNER_LABELS="${runner_labels}"
GITHUB_TOKEN="${github_token}"

apt-get update -y
apt-get install -y curl tar

mkdir -p /opt/actions-runner
cd /opt/actions-runner

curl -Ls -o actions-runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

tar xzf actions-runner.tar.gz

# Necesario para ejecutar como root
export RUNNER_ALLOW_RUNASROOT=1

./config.sh --unattended \
  --url "${GITHUB_URL}" \
  --token "${GITHUB_TOKEN}" \
  --labels "${RUNNER_LABELS}" \
  --name "gcp-$(hostname)" \
  --work "_work"

./svc.sh install
./svc.sh start
