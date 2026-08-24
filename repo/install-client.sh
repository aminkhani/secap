#!/usr/bin/env bash
# =====================================================================
# install-client.sh
#   Runs on the client (the system to be scanned). It detects the 
#   distribution, adds the offline openscap repo as a temporary 
#   source, installs the necessary packages, and finally removes 
#   the temporary source (so the client does not remain permanently 
#   dependent on this server).
#
#   Usage:
#     curl -sSL http://<repo-host>:<port>/install-client.sh | sudo bash -s -- http://<repo-host>:<port>
#   Or:
#     ./install-client.sh http://<repo-host>:<port>
# =====================================================================
set -euo pipefail

REPO_URL="${1:-}"
if [[ -z "$REPO_URL" ]]; then
    echo "Usage: $0 <repo-base-url>   e.g. $0 http://10.0.0.5:8080" >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run with root/sudo privileges." >&2
    exit 1
fi

if command -v oscap >/dev/null 2>&1; then
    echo "openscap is already installed: $(oscap --version | head -1)"
    exit 0
fi

if [[ ! -r /etc/os-release ]]; then
    echo "Cannot detect system distribution (/etc/os-release not found)." >&2
    exit 2
fi
# shellcheck disable=SC1091
source /etc/os-release

install_debian_family() {
    local codename_dir="$1"
    shift
    local packages=("$@")
    local list_file
    list_file="$(mktemp /etc/apt/sources.list.d/oscap-tmp-XXXX.list)"
    echo "deb [trusted=yes] ${REPO_URL}/linux/${codename_dir} ./" > "$list_file"

    # Use ONLY the temp repo for both the index refresh AND the install itself,
    # so apt never falls back to the system's normal sources / the internet.
    local apt_opts=(
        -o Dir::Etc::sourcelist="sources.list.d/$(basename "$list_file")"
        -o Dir::Etc::sourceparts="-"
        -o APT::Get::List-Cleanup="0"
    )

    if ! apt-get update "${apt_opts[@]}"; then
        rm -f "$list_file"
        echo "Failed to fetch package index from ${REPO_URL}/linux/${codename_dir}" >&2
        exit 4
    fi

    if ! apt-get install -y "${apt_opts[@]}" "${packages[@]}"; then
        rm -f "$list_file"
        echo "Package(s) not found in offline repo (${REPO_URL}/linux/${codename_dir}) and internet fallback is disabled." >&2
        exit 4
    fi

    rm -f "$list_file"
    apt-get update >/dev/null 2>&1 || true
}

install_rpm_family() {
    local dir="$1"
    local tmp_repo="/etc/yum.repos.d/oscap-tmp.repo"
    cat > "$tmp_repo" <<EOF
[oscap-tmp]
name=OpenSCAP offline repo
baseurl=${REPO_URL}/linux/${dir}
enabled=1
gpgcheck=0
EOF
    # Disable every other configured repo and use ONLY oscap-tmp, so dnf/yum
    # never resolves packages from the internet even if they're reachable.
    local pkg_mgr_opts=(--disablerepo="*" --enablerepo="oscap-tmp")

    if command -v dnf >/dev/null 2>&1; then
        if ! dnf install -y "${pkg_mgr_opts[@]}" openscap openscap-scanner openscap-utils; then
            rm -f "$tmp_repo"
            echo "Package(s) not found in offline repo (${REPO_URL}/linux/${dir}) and internet fallback is disabled." >&2
            exit 4
        fi
    else
        if ! yum install -y "${pkg_mgr_opts[@]}" openscap openscap-scanner openscap-utils; then
            rm -f "$tmp_repo"
            echo "Package(s) not found in offline repo (${REPO_URL}/linux/${dir}) and internet fallback is disabled." >&2
            exit 4
        fi
    fi
    rm -f "$tmp_repo"
}

case "${ID}" in
    ubuntu)
        case "${VERSION_ID}" in
            # 20.04/22.04: oscap ships inside libopenscap8 itself -
            # openscap-scanner/openscap-utils/openscap-common don't exist for these releases.
            20.04) install_debian_family "ubuntu-20.04" libopenscap8 ;;
            22.04) install_debian_family "ubuntu-22.04" libopenscap8 ;;
            # 24.04: oscap was split out into its own openscap-scanner package.
            24.04) install_debian_family "ubuntu-24.04" openscap-scanner openscap-utils openscap-common ;;
            *)
                echo "Ubuntu version ${VERSION_ID} is not available in the repo. Available list: 20.04 / 22.04 / 24.04" >&2
                echo "Alternatively, you can install directly from the official mirror (if internet is available):" >&2
                echo "  apt-get install -y openscap-scanner openscap-utils openscap-common" >&2
                exit 3
                ;;
        esac
        ;;
    debian)
        case "${VERSION_ID}" in
            12) install_debian_family "debian-12" openscap-scanner openscap-utils openscap-common ;;
            *)
                echo "Debian ${VERSION_ID} is not available in the repo. Available list: 12" >&2
                echo "Alternatively, you can install directly from the official mirror (if internet is available):" >&2
                echo "  apt-get install -y openscap-scanner openscap-utils openscap-common" >&2
                exit 3
                ;;
        esac
        ;;
    rocky)
        case "${VERSION_ID%%.*}" in
            8) install_rpm_family "rocky-8" ;;
            9) install_rpm_family "rocky-9" ;;
            *)
                echo "Rocky Linux ${VERSION_ID} is not available in the repo. Available list: 8 / 9" >&2
                exit 3
                ;;
        esac
        ;;
    almalinux)
        case "${VERSION_ID%%.*}" in
            8) install_rpm_family "alma-8" ;;
            9) install_rpm_family "alma-9" ;;
            *)
                echo "AlmaLinux ${VERSION_ID} is not available in the repo. Available list: 8 / 9" >&2
                exit 3
                ;;
        esac
        ;;
    rhel|centos|fedora)
        echo "${ID} is not pre-built in this repo. Use a Rocky/AlmaLinux equivalent build, or install directly:" >&2
        echo "  dnf install -y openscap openscap-scanner openscap-utils" >&2
        exit 3
        ;;
    *)
        echo "Distribution '${ID}' is not supported. Please install openscap manually." >&2
        exit 3
        ;;
esac

echo "Installation complete: $(oscap --version | head -1)"