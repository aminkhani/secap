#!/usr/bin/env bash

set -Eeuo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-$PWD/repo}"
INCLUDE_SCAP_CONTENT="${INCLUDE_SCAP_CONTENT:-no}"

DISTROS=(
    ubuntu-20.04
    ubuntu-22.04
    ubuntu-24.04
    debian-11
    debian-12
    rocky-8
    rocky-9
    alma-8
    alma-9
    opensuse-15.6
)

log() {
    printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

warn() {
    printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2
}

die() {
    printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2
    exit 1
}

check_requirements() {
    command -v docker >/dev/null 2>&1 ||
        die "Docker is required."

    docker info >/dev/null 2>&1 ||
        die "Docker is not running or the current user cannot access it."

    mkdir -p "$OUTPUT_DIR"
    OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
}

run_container() {
    local image="$1"
    local destination="$2"
    local command="$3"

    mkdir -p "$destination"

    docker run --rm \
        --user root \
        --label "com.secap.component=repo-downloader" \
        --volume "$destination:/output" \
        "$image" \
        /bin/bash -Eeuo pipefail -c "$command"
}
download_debian_repo() {
    local distro="$1"
    local image="$2"
    local destination="$OUTPUT_DIR/linux/$distro"

    log "Downloading OpenSCAP packages for $distro"

    rm -rf "$destination"
    mkdir -p "$destination"

    run_container "$image" "$destination" '
        export DEBIAN_FRONTEND=noninteractive

        apt-get update
        apt-get install -y --no-install-recommends ca-certificates
        update-ca-certificates

        if [ -f /etc/apt/sources.list ]; then
            sed -i \
                -e "s|http://archive.ubuntu.com|https://archive.ubuntu.com|g" \
                -e "s|http://security.ubuntu.com|https://security.ubuntu.com|g" \
                -e "s|http://deb.debian.org|https://deb.debian.org|g" \
                -e "s|http://security.debian.org|https://security.debian.org|g" \
                /etc/apt/sources.list

            if grep -qi "^ID=ubuntu" /etc/os-release; then
                apt-get install -y --no-install-recommends software-properties-common
                add-apt-repository -y universe
            fi
        fi

        if [ -f /etc/apt/sources.list.d/debian.sources ]; then
            sed -i \
                -e "s|http://deb.debian.org|https://deb.debian.org|g" \
                -e "s|http://security.debian.org|https://security.debian.org|g" \
                /etc/apt/sources.list.d/debian.sources
        fi

        apt-get update

        echo "Configured APT sources:"
        grep -RhE "^(deb |URIs:|Suites:|Components:)" \
            /etc/apt/sources.list \
            /etc/apt/sources.list.d 2>/dev/null || true

        available_packages=()

        openscap_candidates=(
            openscap-scanner
            libopenscap25
            libopenscap8
        )

        tool_candidates=(
            openscap-utils
            openscap-common
            python3-openscap
            python-openscap
        )

        content_candidates=()

        if [ "'"$INCLUDE_SCAP_CONTENT"'" = "yes" ]; then
            content_candidates=(
                scap-security-guide
                ssg-base
                ssg-debderived
                ssg-debian
                ssg-ubuntu
                ssg-applications
            )
        fi

        selected_openscap_package=""

        for package in "${openscap_candidates[@]}"; do
            if apt-cache show "$package" >/dev/null 2>&1; then
                selected_openscap_package="$package"
                available_packages+=("$package")
                break
            fi
        done

        if [ -z "$selected_openscap_package" ]; then
            echo "No usable OpenSCAP package found." >&2
            echo "APT search results:" >&2
            apt-cache search openscap >&2 || true
            exit 1
        fi

        for package in "${tool_candidates[@]}" "${content_candidates[@]}"; do
            if apt-cache show "$package" >/dev/null 2>&1; then
                available_packages+=("$package")
            else
                echo "Optional package unavailable: $package" >&2
            fi
        done
        mapfile -t available_packages < <(
            printf "%s\n" "${available_packages[@]}" | sort -u
        )

        echo "Selected OpenSCAP package: $selected_openscap_package"
        echo "Packages selected: ${available_packages[*]}"

        mkdir -p /tmp/openscap-download
        apt-get install -y \
            --download-only \
            -o Dir::Cache::archives=/tmp/openscap-download \
            "${available_packages[@]}"

        find /tmp/openscap-download \
            -maxdepth 1 \
            -type f \
            -name "*.deb" \
            -exec cp -v {} /output/ \;

        find /output \
            -maxdepth 1 \
            -type f \
            -name "*.deb" |
            grep -q . || {
                echo "No DEB files were downloaded" >&2
                exit 1
            }

        apt-get update
        apt-get install -y --no-install-recommends dpkg-dev

        cd /output
        dpkg-scanpackages --multiversion . /dev/null > Packages
        gzip -9fk Packages

        {
            echo "Distribution: '"$distro"'"
            echo "Image: '"$image"'"
            echo "Architecture: $(dpkg --print-architecture)"
            echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "Packages: ${available_packages[*]}"
        } > repository-info.txt

        {
            find . -maxdepth 1 -type f -name "*.deb" -print0
            printf "%s\0" ./Packages ./Packages.gz
        } |
            sort -z |
            xargs -0 sha256sum > SHA256SUMS
    '
}

download_rpm_repo() {
    local distro="$1"
    local image="$2"
    local destination="$OUTPUT_DIR/linux/$distro"

    log "Downloading OpenSCAP packages for $distro"

    rm -rf "$destination"
    mkdir -p "$destination"

    run_container "$image" "$destination" '
        package_manager=dnf
        command -v dnf >/dev/null 2>&1 || package_manager=yum

        "$package_manager" -y install \
            ca-certificates \
            dnf-plugins-core \
            createrepo_c

        if command -v dnf config-manager >/dev/null 2>&1; then
            dnf config-manager --set-enabled powertools >/dev/null 2>&1 || true
            dnf config-manager --set-enabled PowerTools >/dev/null 2>&1 || true
            dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
        fi

        packages=(
            openscap-scanner
            openscap-utils
        )

        if [ "'"$INCLUDE_SCAP_CONTENT"'" = "yes" ]; then
            packages+=(scap-security-guide)
        fi

        available_packages=()

        for package in "${packages[@]}"; do
            if dnf -q list --available "$package" >/dev/null 2>&1 ||
               dnf -q list --installed "$package" >/dev/null 2>&1; then
                available_packages+=("$package")
            else
                echo "Optional package not available: $package" >&2
            fi
        done

        [ "${#available_packages[@]}" -gt 0 ] ||
            { echo "No OpenSCAP packages are available" >&2; exit 1; }

        dnf download \
            --resolve \
            --alldeps \
            --destdir /output \
            "${available_packages[@]}"

        createrepo_c /output

        {
            echo "Distribution: '"$distro"'"
            echo "Image: '"$image"'"
            echo "Architecture: $(uname -m)"
            echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "Packages: ${available_packages[*]}"
        } > /output/repository-info.txt

        cd /output
        find . -maxdepth 1 -type f -name "*.rpm" -print0 |
            sort -z |
            xargs -0 sha256sum > SHA256SUMS
    '
}

download_opensuse_repo() {
    local distro="$1"
    local image="$2"
    local destination="$OUTPUT_DIR/linux/$distro"

    log "Downloading OpenSCAP packages for $distro"

    rm -rf "$destination"
    mkdir -p "$destination"

    run_container "$image" "$destination" '
        zypper --non-interactive refresh

        zypper --non-interactive install \
            ca-certificates \
            createrepo_c

        packages=(
            openscap
            openscap-utils
        )

        if [ "'"$INCLUDE_SCAP_CONTENT"'" = "yes" ]; then
            packages+=(scap-security-guide)
        fi

        available_packages=()

        for package in "${packages[@]}"; do
            if zypper --non-interactive search --match-exact "$package" |
                grep -q "|[[:space:]]*$package[[:space:]]*|"; then
                available_packages+=("$package")
            else
                echo "Optional package not available: $package" >&2
            fi
        done

        [ "${#available_packages[@]}" -gt 0 ] ||
            { echo "No OpenSCAP packages are available" >&2; exit 1; }

        zypper --non-interactive \
            --pkg-cache-dir /tmp/package-cache \
            install \
            --download-only \
            --no-recommends \
            "${available_packages[@]}"

        find /tmp/package-cache \
            -type f \
            -name "*.rpm" \
            -exec cp -v {} /output/ \;

        find /output -maxdepth 1 -type f -name "*.rpm" | grep -q . ||
            { echo "No RPM files were downloaded" >&2; exit 1; }

        createrepo_c /output

        {
            echo "Distribution: '"$distro"'"
            echo "Image: '"$image"'"
            echo "Architecture: $(uname -m)"
            echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "Packages: ${available_packages[*]}"
        } > /output/repository-info.txt

        cd /output
        find . -maxdepth 1 -type f -name "*.rpm" -print0 |
            sort -z |
            xargs -0 sha256sum > SHA256SUMS
    '
}

download_distro() {
    local distro="$1"

    case "$distro" in
        ubuntu-20.04)
            download_debian_repo "$distro" "ubuntu:20.04"
            ;;
        ubuntu-22.04)
            download_debian_repo "$distro" "ubuntu:22.04"
            ;;
        ubuntu-24.04)
            download_debian_repo "$distro" "ubuntu:24.04"
            ;;
        debian-11)
            download_debian_repo "$distro" "debian:11"
            ;;
        debian-12)
            download_debian_repo "$distro" "debian:12"
            ;;
        rocky-8)
            download_rpm_repo "$distro" "rockylinux:8"
            ;;
        rocky-9)
            download_rpm_repo "$distro" "rockylinux:9"
            ;;
        alma-8)
            download_rpm_repo "$distro" "almalinux:8"
            ;;
        alma-9)
            download_rpm_repo "$distro" "almalinux:9"
            ;;
        opensuse-15.6)
            download_opensuse_repo "$distro" "opensuse/leap:15.6"
            ;;
        *)
            die "Unsupported distribution: $distro"
            ;;
    esac
}

write_index() {
    log "Creating repository index"

    {
        echo "OpenSCAP Offline Repositories"
        echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo
        find "$OUTPUT_DIR/linux" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -printf "%f\n" |
            sort
    } > "$OUTPUT_DIR/README.txt"
}

main() {
    check_requirements

    log "Output directory: $OUTPUT_DIR"

    if [ "$#" -gt 0 ]; then
        for distro in "$@"; do
            download_distro "$distro"
        done
    else
        for distro in "${DISTROS[@]}"; do
            if ! download_distro "$distro"; then
                warn "Failed to download packages for $distro"
            fi
        done
    fi

    write_index

    log "Download completed"
    printf 'Files are available in: %s\n' "$OUTPUT_DIR"
}

main "$@"
