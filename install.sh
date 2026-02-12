#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="${BASH_SOURCE[0]:+$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
[[ -n "${BASH_SOURCE[0]:-}" ]] && readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")" || readonly SCRIPT_NAME="install.sh"
readonly SCRIPT_VERSION="1.0.0"
readonly LOG_FILE=$(mktemp /tmp/install.XXXXXX.log)
readonly PLATFORM=$(uname -s)

[[ -t 1 ]] && { readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' NC='\033[0m'; } || { readonly RED='' GREEN='' YELLOW='' BLUE='' NC=''; }

log_msg() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }

debug() { [[ "${DEBUG:-0}" == "1" ]] && echo "[DEBUG] $*" >&2; }

get_color() {
case "$1" in
RED) echo "$RED" ;;
GREEN) echo "$GREEN" ;;
YELLOW) echo "$YELLOW" ;;
BLUE) echo "$BLUE" ;;
esac
}

msg() { 
local color=$(get_color "$1") text="${*:2}"
printf "%b[%s]%b %s\n" "$color" "$1" "$NC" "$text"
log_msg "[$1] $text"
}
err() { 
printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*" >&2
log_msg "[ERROR] $*"
}

# Cross-platform user info functions
get_user_home() {
    local user="$1"
    if [[ "$PLATFORM" == "Darwin" ]]; then
        dscl . -read /Users/"$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
    else
        getent passwd "$user" 2>/dev/null | cut -d: -f6
    fi
}

get_user_shell() {
    local user="$1"
    if [[ "$PLATFORM" == "Darwin" ]]; then
        dscl . -read /Users/"$user" UserShell 2>/dev/null | awk '{print $2}'
    else
        getent passwd "$user" 2>/dev/null | cut -d: -f7
    fi
}

# Set ownership to SUDO_USER if running under sudo
set_ownership() {
    local target="$1"
    local recursive="${2:-}"

    [[ -z "${SUDO_USER:-}" ]] && return 0

    local user_group
    user_group=$(id -gn "$SUDO_USER" 2>/dev/null) || {
        err "Failed to get group for $SUDO_USER"
        return 1
    }

    if [[ "$recursive" == "-R" ]]; then
        chown -R "${SUDO_USER}:${user_group}" "$target"
    else
        chown "${SUDO_USER}:${user_group}" "$target"
    fi
}

cleanup() {
    local c=$?; [[ $c -ne 0 ]] && err "Installation failed. Check log: $LOG_FILE"
    [[ -f "${TEMP_DIR:-}/.zshrc.tmp" ]] && rm -f "$TEMP_DIR/.zshrc.tmp"
    exit $c
}
trap cleanup EXIT

show_help() {
cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Install zsh configuration and dependencies.

Options:
    -h, --help      Show this help message
    -v, --version   Show version
    -d, --dry-run   Show what would be done without executing
    --no-backup     Skip dotfile backup
    --no-shell      Skip shell change
    --debug         Enable debug output

Examples:
    sudo $SCRIPT_NAME
    sudo $SCRIPT_NAME --dry-run
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_help; exit 0 ;;
            -v|--version) echo "$SCRIPT_NAME version $SCRIPT_VERSION"; exit 0 ;;
            -d|--dry-run) DRY_RUN=1; shift ;;
            --no-backup) NO_BACKUP=1; shift ;;
            --no-shell) NO_SHELL=1; shift ;;
            --debug) DEBUG=1; shift ;;
            *) err "Unknown option: $1"; show_help; exit 1 ;;
        esac
    done
}

check_sudo() {
if [[ $EUID -ne 0 ]]; then
err "This script must be run with sudo or as root (EUID=$EUID)"
exit 1
fi
    if [[ -n "${SUDO_USER:-}" ]]; then
        # Validate username format while preventing path traversal
        # Rejects: .., /, . (hidden files), leading/trailing dots, path patterns
        if [[ "$SUDO_USER" == *".."* ]]; then
            err "SUDO_USER contains path traversal pattern: ${SUDO_USER}"
            exit 1
        fi
        if [[ "$SUDO_USER" == */* ]]; then
            err "SUDO_USER contains path separator: ${SUDO_USER}"
            exit 1
        fi
        if [[ "$SUDO_USER" == .* ]]; then
            err "SUDO_USER starts with a dot: ${SUDO_USER}"
            exit 1
        fi
        if [[ "$SUDO_USER" == *. ]]; then
            err "SUDO_USER ends with a dot: ${SUDO_USER}"
            exit 1
        fi
        if [[ ! "$SUDO_USER" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            err "Invalid SUDO_USER format: ${SUDO_USER}"
            exit 1
        fi
        if ! id "$SUDO_USER" &>/dev/null; then
            err "Invalid SUDO_USER: user does not exist: ${SUDO_USER}"
            exit 1
        fi
    fi
}

detect_os() {
    case "$PLATFORM" in
    Linux)
        OS="linux"
        [[ -f /etc/os-release ]] || { err "Cannot detect Linux distribution"; exit 1; }
        source /etc/os-release
        # Validate distribution ID to prevent injection from compromised os-release
        [[ "${ID:-}" =~ ^[a-zA-Z0-9._-]+$ ]] || { err "Invalid distribution ID format: ${ID:-unknown}"; exit 1; }
        case "${ID:-}" in
                ubuntu|debian) PKG_MGR="apt" ;;
                fedora|rhel|centos|rocky|almalinux) PKG_MGR=$(command -v dnf &>/dev/null && echo "dnf" || command -v yum &>/dev/null && echo "yum" || { err "No supported package manager"; exit 1; }) ;;
                arch|manjaro) PKG_MGR="pacman" ;;
                opensuse*|suse*) PKG_MGR="zypper" ;;
                *) err "Unsupported Linux distribution: ${ID:-unknown}"; exit 1 ;;
            esac
            ;;
        Darwin)
            OS="macos"; PKG_MGR="brew"
            command -v brew &>/dev/null || { err "Homebrew not found. Install from https://brew.sh"; exit 1; }
            ;;
        *) err "Unsupported OS"; exit 1 ;;
    esac
    msg GREEN "Detected OS: $OS, Package manager: $PKG_MGR"
}

# Package manager command dispatch
run_pkg() {
    local action=$1; shift
    local dry="${DRY_RUN:-0}"
    local -a packages=("$@")

    [[ "$dry" == "1" ]] && { msg GREEN "[DRY-RUN] Would $action packages"; return 0; }

    # Build safe package list for brew
    local safe_pkgs=""
    if [[ ${#packages[@]} -gt 0 ]]; then
        for pkg in "${packages[@]}"; do
            # Validate package name: alphanumeric, hyphens, dots only
            if [[ "$pkg" =~ ^[a-zA-Z0-9._-]+$ ]]; then
                safe_pkgs="${safe_pkgs}${safe_pkgs:+ }${pkg}"
            else
                err "Invalid package name: $pkg"
                return 1
            fi
        done
    fi

    case "${action}_$PKG_MGR" in
        update_brew) su - "$SUDO_USER" -c 'brew update && brew upgrade' ;;
        install_brew) su - "$SUDO_USER" -c "brew install --quiet ${safe_pkgs}" ;;
        cleanup_brew) su - "$SUDO_USER" -c 'brew cleanup --prune=all && brew autoremove' ;;
update_apt) apt-get update && apt-get upgrade -y ;;
install_apt) apt-get install -y "$@" ;;
cleanup_apt) apt-get autoremove -y && apt-get autoclean ;;
update_dnf) dnf update -y ;;
install_dnf) dnf install -y "$@" ;;
cleanup_dnf) dnf autoremove -y ;;
update_yum) yum update -y ;;
install_yum) yum install -y "$@" ;;
cleanup_yum) yum autoremove -y ;;
update_pacman) pacman -Syu --noconfirm ;;
install_pacman) pacman -S --noconfirm "$@" ;;
cleanup_pacman) pacman -Qdtq 2>/dev/null | pacman -Rns --noconfirm - 2>/dev/null || true; pacman -Sc --noconfirm ;;
update_zypper) zypper update -y ;;
install_zypper) zypper install -y "$@" ;;
cleanup_zypper) zypper packages --unneeded | grep "|" | grep -v "Name" | awk -F'|' '{print $3}' | xargs -r zypper remove -y 2>/dev/null || true; zypper clean ;;
    esac
}

update_packages() { msg GREEN "Updating packages..."; run_pkg update; }

install_packages() { msg GREEN "Installing packages (git, zsh, curl, wget)..."; run_pkg install git zsh curl wget; }

backup_dotfiles() {
    [[ "${NO_BACKUP:-0}" == "1" ]] && { msg GREEN "Skipping backup"; return 0; }
    msg GREEN "Backing up dotfiles..."
    
    local dir="$REAL_HOME/.dotfiles_backup_$(date +%Y%m%d_%H%M%S)"
    [[ "${DRY_RUN:-0}" == "1" ]] && { msg GREEN "[DRY-RUN] Would backup to: $dir"; return 0; }
    
    mkdir -p "$dir" || { err "Failed to create backup directory"; exit 1; }
    
    local files=(".bashrc" ".bash_profile" ".profile" ".zshrc" ".zprofile" ".zlogin" ".zlogout")
    local to_backup=()
    for f in "${files[@]}"; do [[ -f "$REAL_HOME/$f" ]] && to_backup+=("$f"); done
    
    [[ ${#to_backup[@]} -eq 0 ]] && { msg GREEN "No dotfiles to backup"; rmdir "$dir" 2>/dev/null || true; return 0; }
    
    tar -czf "$dir/dotfiles.tar.gz" -C "$REAL_HOME" "${to_backup[@]}" 2>/dev/null && msg GREEN "Backed up ${#to_backup[@]} file(s)" || msg YELLOW "Some files could not be backed up"
    set_ownership "$dir" -R || return 1
    msg GREEN "Backup complete: $dir"
}

download_zshrc() {
    msg GREEN "Downloading .zshrc configuration..."
    local base_url="https://raw.githubusercontent.com/Oculto54/Utils/main"
    local url="${base_url}/.zshrc"
    local checksum_url="${base_url}/.zshrc.sha256"
    local tmp="$TEMP_DIR/.zshrc.tmp"
    local checksum_tmp="$TEMP_DIR/.zshrc.sha256.tmp"
    local target="$REAL_HOME/.zshrc"

    [[ "${DRY_RUN:-0}" == "1" ]] && { msg GREEN "[DRY-RUN] Would download: $url"; return 0; }

    # Download .zshrc
    local ok=0
    command -v curl &>/dev/null && curl -fsSL --max-time 30 --retry 3 "$url" -o "$tmp" && ok=1
    [[ $ok -eq 0 ]] && command -v wget &>/dev/null && wget -q --timeout=30 --tries=3 "$url" -O "$tmp" && ok=1
    [[ $ok -eq 0 ]] && { err "Failed to download .zshrc"; exit 1; }

    # Download checksum file
    ok=0
    command -v curl &>/dev/null && curl -fsSL --max-time 30 --retry 3 "$checksum_url" -o "$checksum_tmp" && ok=1
    [[ $ok -eq 0 ]] && command -v wget &>/dev/null && wget -q --timeout=30 --tries=3 "$checksum_url" -O "$checksum_tmp" && ok=1
    [[ $ok -eq 0 ]] && { err "Failed to download .zshrc.sha256"; rm -f "$tmp"; exit 1; }

    # Verify SHA256 checksum
    local expected_hash computed_hash
    expected_hash=$(awk '{print $1}' "$checksum_tmp" 2>/dev/null)
    [[ -z "$expected_hash" ]] && { err "Failed to read expected hash"; rm -f "$tmp" "$checksum_tmp"; exit 1; }

    # Validate hash format (64 hex characters)
    [[ "$expected_hash" =~ ^[a-fA-F0-9]{64}$ ]] || { err "Invalid hash format in checksum file"; rm -f "$tmp" "$checksum_tmp"; exit 1; }

    # Compute hash of downloaded file
    if command -v sha256sum &>/dev/null; then
        computed_hash=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        computed_hash=$(shasum -a 256 "$tmp" 2>/dev/null | awk '{print $1}')
    else
        err "Neither sha256sum nor shasum found"
        rm -f "$tmp" "$checksum_tmp"
        exit 1
    fi

    # Strict verification - fail if mismatch
    [[ "$computed_hash" != "$expected_hash" ]] && {
        err "SHA256 verification failed!"
        err "Expected: $expected_hash"
        err "Computed: $computed_hash"
        rm -f "$tmp" "$checksum_tmp"
        exit 1
    }

    msg GREEN "SHA256 verification passed"

    # Additional validation
    [[ -s "$tmp" ]] || { err "Downloaded file is empty"; rm -f "$tmp" "$checksum_tmp"; exit 1; }
    grep -qE "(zsh|#!/bin)" "$tmp" 2>/dev/null || { err "Downloaded file invalid"; rm -f "$tmp" "$checksum_tmp"; exit 1; }

    mv -f "$tmp" "$target" || { err "Failed to install .zshrc"; exit 1; }
    rm -f "$checksum_tmp"
    chmod 644 "$target"
    set_ownership "$target" || exit 1
    msg GREEN "Successfully installed .zshrc"
}

create_root_symlinks() {
    # Only create root symlinks if: Linux + sudo + /root exists
    [[ "$OS" != "linux" ]] && { msg GREEN "Skipping root symlinks (not Linux)"; return 0; }
    [[ -z "${SUDO_USER:-}" ]] && { msg GREEN "Skipping root symlinks (not running as sudo)"; return 0; }
    [[ ! -d "/root" ]] && { msg GREEN "Skipping root symlinks (/root not found)"; return 0; }
    # Prevent symlink loop if REAL_HOME is /root
    [[ "$REAL_HOME" == "/root" ]] && { msg GREEN "Skipping root symlinks (home is /root)"; return 0; }

    msg GREEN "Creating symbolic links for root..."
    [[ "${DRY_RUN:-0}" == "1" ]] && { msg GREEN "[DRY-RUN] Would create symlinks in /root"; return 0; }

    local -a files=(".zshrc" ".p10k.zsh" ".nanorc")
    local target created_count=0

    for f in "${files[@]}"; do
        target="$REAL_HOME/$f"

        # Security: Verify target is within REAL_HOME (prevent traversal)
        [[ "$target" != "$REAL_HOME"/* ]] && { err "Security: Target $target outside home directory"; continue; }

        # Only symlink existing regular files (skip if missing or not a regular file)
        # This prevents TOCTOU - we don't create files, only symlink existing ones
        if [[ -f "$target" ]]; then
            # Verify file is owned by SUDO_USER (prevent symlink to attacker-controlled file)
            local file_owner
            file_owner=$(stat -c '%U' "$target" 2>/dev/null) || file_owner=$(stat -f '%Su' "$target" 2>/dev/null)
            if [[ "$file_owner" != "$SUDO_USER" ]]; then
                err "Security: $target not owned by $SUDO_USER (owner: $file_owner)"
                continue
            fi

            # Create symlink atomically
            ln -sf "$target" "/root/$f" && ((created_count++))
        fi
    done

    [[ $created_count -gt 0 ]] && msg GREEN "Created $created_count symbolic link(s) in /root"
}

change_shell() {
    [[ "${NO_SHELL:-0}" == "1" ]] && { msg GREEN "Skipping shell change"; return 0; }
    msg GREEN "Changing shell to zsh..."
    
    local zsh_path=$(command -v zsh)
    [[ -z "$zsh_path" ]] && { err "zsh not found"; exit 1; }
    [[ "${DRY_RUN:-0}" == "1" ]] && { msg GREEN "[DRY-RUN] Would change shell to: $zsh_path"; return 0; }
    [[ ! -x "$zsh_path" ]] && { err "zsh not executable"; exit 1; }
    
    if ! grep -qx "$zsh_path" /etc/shells 2>/dev/null; then
        if [[ "$zsh_path" =~ ^/[^[:space:]]+/zsh$ ]]; then
            # Verify the path actually exists and is a regular executable file
            if [[ -f "$zsh_path" && -x "$zsh_path" ]]; then
                echo "$zsh_path" >> /etc/shells
                msg GREEN "Added $zsh_path to /etc/shells"
            else
                err "zsh path does not exist or is not executable: $zsh_path"
                exit 1
            fi
        else
            err "Invalid zsh path format: $zsh_path"
            exit 1
        fi
    fi
    
    local u_shell=$(get_user_shell "$REAL_USER")
    [[ "$u_shell" != "$zsh_path" ]] && { chsh -s "$zsh_path" "$REAL_USER"; msg GREEN "Changed shell for $REAL_USER"; } || msg GREEN "Shell already set for $REAL_USER"

    if [[ "$OS" == "macos" ]]; then
        msg GREEN "Skipping root shell change (not needed on macOS)"
    else
        local r_shell=$(get_user_shell "root")
        [[ "$r_shell" != "$zsh_path" ]] && { chsh -s "$zsh_path" root; msg GREEN "Changed shell for root"; } || msg GREEN "Shell already set for root"
    fi
}

verify_installation() {
    msg GREEN "Verifying installation..."
    local e=0
    command -v git &>/dev/null && msg GREEN "Git: $(git --version 2>&1 | head -1)" || { err "Git not found"; ((e++)); }
    command -v zsh &>/dev/null && msg GREEN "Zsh: $(zsh --version 2>&1 | head -1)" || { err "Zsh not found"; ((e++)); }
    [[ -f "$REAL_HOME/.zshrc" ]] && msg GREEN ".zshrc: installed ($(wc -l < "$REAL_HOME/.zshrc") lines)" || { err ".zshrc not found"; ((e++)); }
    [[ $e -gt 0 ]] && { err "Verification failed with $e error(s)"; exit 1; }
    msg GREEN "All checks passed"
}

cleanup_packages() { msg GREEN "Cleaning up unnecessary packages..."; run_pkg cleanup; }

main() {
readonly TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"; cleanup' EXIT

parse_args "$@"

readonly REAL_USER="${SUDO_USER:-$(whoami)}"
    readonly REAL_HOME=$(get_user_home "$REAL_USER")
    [[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]] && { err "Cannot determine home directory"; exit 1; }

    msg GREEN "Starting installation for user: $REAL_USER (home: $REAL_HOME)"

    check_sudo
    detect_os
update_packages
install_packages
backup_dotfiles
download_zshrc
create_root_symlinks
change_shell
verify_installation
cleanup_packages

msg GREEN "=========================================="
msg GREEN "Installation complete!"
msg GREEN "=========================================="
msg GREEN "Log saved to: $LOG_FILE"
msg GREEN "Next steps: 1. Log out and back in 2. Run 'zsh'"
if [[ "${NO_BACKUP:-0}" != "1" ]]; then
local last_backup
last_backup=$(ls -d "$REAL_HOME/.dotfiles_backup_"* 2>/dev/null | tail -1)
[[ -n "$last_backup" ]] && msg GREEN "Backup: $last_backup"
fi
}

main "$@"
