#!/usr/bin/env bash

package_installed() {
    local status
    status=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || return 1
    [[ $status == 'install ok installed' ]]
}

docker_source_enabled() {
    local file=$1 deb822=0
    [[ $file != *.sources ]] || deb822=1
    awk -v deb822="$deb822" '
        BEGIN { RS = deb822 ? "" : "\n" }
        {
            if (!deb822) {
                line = $0
                sub(/#.*/, "", line)
                if (line ~ /^[[:space:]]*deb[[:space:]]/ &&
                    line ~ /[[:space:]]https?:\/\/download[.]docker[.]com\/linux\/debian\/?([[:space:]]|$)/) found = 1
                next
            }
            enabled = types = uris = field = ""
            count = split($0, lines, "\n")
            for (i = 1; i <= count; i++) {
                line = lines[i]
                if (line ~ /^[[:space:]]*#/) continue
                if (line ~ /^[[:space:]]+/) value = line
                else {
                    colon = index(line, ":")
                    if (!colon) { field = ""; continue }
                    field = tolower(substr(line, 1, colon - 1))
                    value = substr(line, colon + 1)
                }
                if (field == "enabled") enabled = enabled " " tolower(value)
                if (field == "types") types = types " " value
                if (field == "uris") uris = uris " " value
            }
            if (enabled !~ /(^|[[:space:]])no([[:space:]]|$)/ &&
                types ~ /(^|[[:space:]])deb([[:space:]]|$)/ &&
                uris ~ /(^|[[:space:]])https?:\/\/download[.]docker[.]com\/linux\/debian\/?([[:space:]]|$)/) found = 1
        }
        END { exit !found }
    ' "$file"
}

check_docker_sources() {
    local directory=$1 file
    DOCKER_REUSE_SOURCE=0
    for file in "$directory/sources.list" "$directory"/sources.list.d/*.list "$directory"/sources.list.d/*.sources; do
        [[ -f $file ]] || continue
        if docker_source_enabled "$file"; then
            DOCKER_REUSE_SOURCE=1
            log "Reusing existing Docker repository: $file (APT will validate repository metadata and signatures)."
        fi
    done
}

docker_preflight() {
    local package unit state
    case "$(dpkg --print-architecture)" in
        amd64|arm64|armhf|ppc64el) ;;
        *) die 'This architecture is not supported by this Docker installer.' ;;
    esac
    for package in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do
        if package_installed "$package"; then
            die "Conflicting package $package is installed. Migrate it manually before selecting Docker installation."
        fi
    done
    if command -v dockerd >/dev/null && ! package_installed docker-ce; then
        die 'An unmanaged Docker daemon is already installed; migrate it manually first.'
    fi
    for unit in docker.service docker.socket containerd.service; do
        state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
        [[ $state != masked* ]] || die "$unit is masked; resolve this before selecting Docker installation."
    done
    check_docker_sources /etc/apt
    if ((DOCKER_REUSE_SOURCE == 0)); then
        [[ ! -L /etc/apt/keyrings/docker.asc && ! -L /etc/apt/sources.list.d/docker.sources ]] ||
            die 'Docker repository files must not be symlinks.'
    fi
}

render_docker_source() {
    cat <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
}

release_docker_masks() {
    if ((${#DOCKER_TEMP_UNITS[@]})); then
        systemctl unmask --runtime "${DOCKER_TEMP_UNITS[@]}"
        DOCKER_TEMP_UNITS=()
    fi
}

install_docker_packages() {
    local unit
    # Prevent first-time package installation from starting container networking
    # before UFW is configured. Existing daemons are never masked or stopped here.
    if ! package_installed docker-ce; then
        for unit in docker.service docker.socket; do
            DOCKER_TEMP_UNITS+=("$unit")
            systemctl mask --runtime "$unit"
        done
    fi
    if ! package_installed containerd.io; then
        DOCKER_TEMP_UNITS+=(containerd.service)
        systemctl mask --runtime containerd.service
    fi
    if ((DOCKER_REUSE_SOURCE == 0)); then
        curl --fail --silent --show-error --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 \
            --retry 2 --max-filesize 1048576 https://download.docker.com/linux/debian/gpg -o "$RUN_DIR/docker.asc"
        grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----' "$RUN_DIR/docker.asc" || die 'Invalid Docker signing key response.'
        install -d -m 0755 /etc/apt/keyrings
        write_config /etc/apt/keyrings/docker.asc < "$RUN_DIR/docker.asc"
        render_docker_source | write_config /etc/apt/sources.list.d/docker.sources
    fi
    apt_run update --error-on=any
    apt_run install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

start_docker() {
    release_docker_masks
    timeout 60 systemctl enable --now containerd.service docker.service
    verify_docker
}

verify_docker() {
    systemctl is-active --quiet docker.service
    timeout 20 env -u DOCKER_HOST -u DOCKER_CONTEXT docker --host unix:///var/run/docker.sock version --format '{{.Server.Version}}'
    timeout 20 docker compose version
    timeout 20 docker buildx version
}
