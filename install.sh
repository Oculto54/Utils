#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run with sudo or as root"
        exit 1
    fi
}

detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"; PKG_MGR="brew"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS="linux"
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            case "$ID" in
                ubuntu|debian) PKG_MGR="apt" ;;
                fedora|rhel|centos|rocky|almalinux) 
                    if command -v dnf &> /dev/null; then PKG_MGR="dnf"; else PKG_MGR="yum"; fi ;;
                arch|manjaro) PKG_MGR="pacman" ;;
                opensuse*|suse*) PKG_MGR="zypper" ;;
                *) print_error "Unsupported Linux distribution: $ID"; exit 1 ;;
            esac
        fi
    else
        print_error "Unsupported OS: $OSTYPE"; exit 1
    fi
    print_info "Detected OS: $OS, Package manager: $PKG_MGR"
}

update_packages() {
    print_info "Updating packages..."
    case "$PKG_MGR" in
        brew) su - "$SUDO_USER" -c "brew update && brew upgrade" ;;
        apt) apt update && apt upgrade -y ;;
        dnf) dnf update -y ;;
        yum) yum update -y ;;
        pacman) pacman -Syu --noconfirm ;;
        zypper) zypper update -y ;;
    esac
}

install_packages() {
    print_info "Installing git and zsh..."
    case "$PKG_MGR" in
        brew) su - "$SUDO_USER" -c "brew install git zsh" ;;
        apt) apt install -y git zsh ;;
        dnf) dnf install -y git zsh ;;
        yum) yum install -y git zsh ;;
        pacman) pacman -S --noconfirm git zsh ;;
        zypper) zypper install -y git zsh ;;
    esac
}

backup_dotfiles() {
    print_info "Backing up dotfiles..."
    REAL_USER="${SUDO_USER:-$(whoami)}"
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    BACKUP_DIR="$REAL_HOME/.dotfiles_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    for file in .bashrc .bash_profile .profile .zshrc .zprofile .zlogin .zlogout; do
        [ -f "$REAL_HOME/$file" ] && cp "$REAL_HOME/$file" "$BACKUP_DIR/" && print_info "Backed up: $file"
    done
    
    [ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$BACKUP_DIR"
    print_info "Backed up to: $BACKUP_DIR"
}

change_shell() {
    print_info "Changing shell to zsh..."
    REAL_USER="${SUDO_USER:-$(whoami)}"
    ZSH_PATH=$(which zsh)
    
    grep -q "^$ZSH_PATH$" /etc/shells || echo "$ZSH_PATH" >> /etc/shells
    
    chsh -s "$ZSH_PATH" "$REAL_USER"
    chsh -s "$ZSH_PATH" root
    
    print_info "Shell changed for $REAL_USER and root"
}

verify_installation() {
    print_info "Verifying..."
    command -v git &> /dev/null && print_info "Git: $(git --version)" || { print_error "Git failed"; exit 1; }
    command -v zsh &> /dev/null && print_info "Zsh: $(zsh --version)" || { print_error "Zsh failed"; exit 1; }
}

main() {
    check_sudo
    detect_os
    update_packages
    install_packages
    backup_dotfiles
    change_shell
    verify_installation
    
    print_info "Installation complete! Log out and back in to use zsh."
}

main "$@"
