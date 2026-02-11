#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="${BASH_SOURCE[0]:+$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
[[ -n "${BASH_SOURCE[0]:-}" ]] && readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")" || readonly SCRIPT_NAME="install.sh"
readonly SCRIPT_VERSION="1.0.0"
readonly LOG_FILE="/tmp/install_$(date +%Y%m%d_%H%M%S).log"

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
if [[ -n "${SUDO_USER:-}" ]] && ! id "$SUDO_USER" &>/dev/null; then
err "Invalid SUDO_USER: ${SUDO_USER}"
exit 1
fi
}

detect_os() {
    case "$(uname -s)" in
        Linux)
            OS="linux"
            [[ -f /etc/os-release ]] || { err "Cannot detect Linux distribution"; exit 1; }
            source /etc/os-release
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
    
    [[ "$dry" == "1" ]] && { msg GREEN "[DRY-RUN] Would $action packages"; return 0; }
    
    case "${action}_$PKG_MGR" in
        update_brew) su - "$SUDO_USER" -c 'brew update && brew upgrade' ;;
        install_brew) su - "$SUDO_USER" -c "brew install --quiet $*" ;;
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
    [[ -n "${SUDO_USER:-}" ]] && chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$dir"
    msg GREEN "Backup complete: $dir"
}

download_zshrc() {
    msg GREEN "Downloading .zshrc configuration..."
    local url="https://raw.githubusercontent.com/Oculto54/Utils/main/.zshrc"
    local tmp="$TEMP_DIR/.zshrc.tmp"
    local target="$REAL_HOME/.zshrc"
    
    [[ "${DRY_RUN:-0}" == "1" ]] && { msg GREEN "[DRY-RUN] Would download: $url"; return 0; }
    
    local ok=0
    command -v curl &>/dev/null && curl -fsSL --max-time 30 --retry 3 "$url" -o "$tmp" && ok=1
    [[ $ok -eq 0 ]] && command -v wget &>/dev/null && wget -q --timeout=30 --tries=3 "$url" -O "$tmp" && ok=1
    [[ $ok -eq 0 ]] && { err "Failed to download .zshrc"; exit 1; }
    
    [[ -s "$tmp" ]] && grep -qE "(zsh|#!/bin)" "$tmp" 2>/dev/null || { err "Downloaded file invalid"; exit 1; }
    
    mv -f "$tmp" "$target" || { err "Failed to install .zshrc"; exit 1; }
    chmod 644 "$target"
    [[ -n "${SUDO_USER:-}" ]] && chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$target"
    msg GREEN "Successfully installed .zshrc"
}

create_root_symlinks() {
    # Only create root symlinks if: Linux + sudo + /root exists
    [[ "$OS" != "linux" ]] && { msg GREEN "Skipping root symlinks (not Linux)"; return 0; }
    [[ -z "${SUDO_USER:-}" ]] && { msg GREEN "Skipping root symlinks (not running as sudo)"; return 0; }
    [[ ! -d "/root" ]] && { msg GREEN "Skipping root symlinks (/root not found)"; return 0; }
    
    msg GREEN "Creating symbolic links for root..."
    [[ "${DRY_RUN:-0}" == "1" ]] && { msg GREEN "[DRY-RUN] Would create symlinks in /root"; return 0; }
    
    for f in ".zshrc" ".p10k.zsh" ".nanorc"; do
        local p="$REAL_HOME/$f"
        [[ ! -f "$p" ]] && { touch "$p" 2>/dev/null || true; chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$p" 2>/dev/null || true; }
        [[ -f "$p" ]] && ln -sf "$p" "/root/$f"
    done
    msg GREEN "Root symbolic links created"
}

change_shell() {
    [[ "${NO_SHELL:-0}" == "1" ]] && { msg GREEN "Skipping shell change"; return 0; }
    msg GREEN "Changing shell to zsh..."
    
    local zsh_path=$(command -v zsh)
    [[ -z "$zsh_path" ]] && { err "zsh not found"; exit 1; }
    [[ "${DRY_RUN:-0}" == "1" ]] && { msg GREEN "[DRY-RUN] Would change shell to: $zsh_path"; return 0; }
    [[ ! -x "$zsh_path" ]] && { err "zsh not executable"; exit 1; }
    
    grep -qx "$zsh_path" /etc/shells 2>/dev/null || { echo "$zsh_path" >> /etc/shells; msg GREEN "Added $zsh_path to /etc/shells"; }
    
    local u_shell=$(getent passwd "$REAL_USER" | cut -d: -f7)
    [[ "$u_shell" != "$zsh_path" ]] && { chsh -s "$zsh_path" "$REAL_USER"; msg GREEN "Changed shell for $REAL_USER"; } || msg GREEN "Shell already set for $REAL_USER"
    
    local r_shell=$(getent passwd root | cut -d: -f7)
    [[ "$r_shell" != "$zsh_path" ]] && { chsh -s "$zsh_path" root; msg GREEN "Changed shell for root"; } || msg GREEN "Shell already set for root"
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
readonly REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
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
