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
    print_info "Installing git, zsh, curl, and wget..."
    case "$PKG_MGR" in
        brew) su - "$SUDO_USER" -c "brew install git zsh curl wget" ;;
        apt) apt install -y git zsh curl wget ;;
        dnf) dnf install -y git zsh curl wget ;;
        yum) yum install -y git zsh curl wget ;;
        pacman) pacman -S --noconfirm git zsh curl wget ;;
        zypper) zypper install -y git zsh curl wget ;;
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

download_zshrc() {
    print_info "Downloading .zshrc configuration..."
    REAL_USER="${SUDO_USER:-$(whoami)}"
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    ZSHRC_URL="https://raw.githubusercontent.com/Oculto54/Utils/main/.zshrc"

    if command -v curl &> /dev/null; then
        curl -fsSL "$ZSHRC_URL" -o "$REAL_HOME/.zshrc"
    elif command -v wget &> /dev/null; then
        wget -q "$ZSHRC_URL" -O "$REAL_HOME/.zshrc"
    else
        print_error "Neither curl nor wget found. Cannot download .zshrc"
        exit 1
    fi

    if [[ ! -f "$REAL_HOME/.zshrc" ]] || [[ ! -s "$REAL_HOME/.zshrc" ]] || ! grep -q "zsh" "$REAL_HOME/.zshrc"; then
        print_error "Failed to download or verify .zshrc"
        exit 1
    fi

    [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$REAL_HOME/.zshrc"
    print_info "Successfully installed .zshrc"
}

create_root_symlinks() {
    # Only create root symlinks on Linux (macOS doesn't use /root)
    if [[ "$OS" == "linux" ]]; then
        print_info "Creating symbolic links for root..."
        REAL_USER="${SUDO_USER:-$(whoami)}"
        REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

        # Create empty files if they don't exist (will be populated by .zshrc)
        touch "$REAL_HOME/.p10k.zsh" 2>/dev/null || true
        touch "$REAL_HOME/.nanorc" 2>/dev/null || true

        # Create symbolic links for root
        ln -sf "$REAL_HOME/.zshrc" /root/.zshrc
        ln -sf "$REAL_HOME/.p10k.zsh" /root/.p10k.zsh
        ln -sf "$REAL_HOME/.nanorc" /root/.nanorc

        print_info "Root symbolic links created"
    else
        print_info "Skipping root symlinks (not applicable for $OS)"
    fi
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
    download_zshrc
    change_shell
    verify_installation
    create_root_symlinks

    print_info "Installation complete! Log out and back in to use zsh."
}

main "$@"
