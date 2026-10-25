#!/usr/bin/env bash
# Validate official Docker packages in a disposable container without a host socket.
set -Eeuo pipefail
[[ -f /.dockerenv ]] || { echo 'Use a disposable Docker container.' >&2; exit 1; }
cd /source
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl > /tmp/docker-test-deps.log 2>&1
source lib/common.sh
source lib/system.sh
source lib/docker.sh
defaults
RUN_DIR=$(mktemp -d)
# PID 1 is not systemd in this package test. Official image policy-rc.d prevents
# maintainer scripts from starting services; service ordering has separate tests.
systemctl() { :; }
docker_preflight
install_docker_packages > "$RUN_DIR/install.log" 2>&1 || {
    tail -60 "$RUN_DIR/install.log"
    exit 1
}
docker --version
docker compose version
docker buildx version
printf '{}\n' > "$RUN_DIR/daemon.json"
dockerd --validate --config-file "$RUN_DIR/daemon.json"
for package in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
    package_installed "$package"
done
release_docker_masks
echo 'Official Docker package installation checks passed.'
