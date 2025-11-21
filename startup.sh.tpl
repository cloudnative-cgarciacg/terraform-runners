#!/bin/bash

GITHUB_URL="${github_url}"
RUNNER_VERSION="${runner_version}"
RUNNER_LABELS="${runner_labels}"
GITHUB_TOKEN="${github_token}"

apt-get update -y
apt-get install -y curl tar

mkdir -p /opt/actions-runner
cd /opt/actions-runner

curl -Ls -o actions-runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v${runner_version}/actions-runner-linux-x64-${runner_version}.tar.gz"

tar xzf actions-runner.tar.gz

./config.sh --unattended \
  --url "${github_url}" \
  --token "${github_token}" \
  --labels "${runner_labels}" \
  --name "gcp-$(hostname)" \
  --work "_work"

./svc.sh install
./svc.sh start
