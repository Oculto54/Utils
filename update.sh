#!/usr/bin/env zsh
# Dotfiles Update/Install Script
# Usage: ./update.sh [--force]

set -uo pipefail  # Removed -e to allow graceful error handling

# Colors
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' CYAN='\033[0;36m' NC='\033[0m'
readonly REPO_URL="https://raw.githubusercontent.com/Oculto54/Utils/main"

# Global state
FORCE_MODE=false
OS=""
SUDO_PREFIX=""

# Helpers
msg()   { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$1"; }
warn()  { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$1"; }
err()   { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$1" >&2; }

# Ask user yes/no
ask() {
    [[ "$FORCE_MODE" == true ]] && return 0
    [[ ! -t 0 ]] && return 0
    local question="$1" default="${2:-y}" yn
    printf "%b[ASK]%b %s [y/n]: " "$CYAN" "$NC" "$question"
    read yn
    case $yn in
        [Yy]*) return 0 ;;
        [Nn]*) return 1 ;;
        "") [[ "$default" == "y" ]] && return 0 || return 1 ;;
        *) msg "Please answer yes or no." ;;
    esac
}

# OS Detection
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]] || [[ -f /etc/debian_version ]]; then
        OS="linux"
    else
        err "Unsupported OS: $OSTYPE"
        exit 1
    fi
    msg "Detected OS: $OS"
}

# Init sudo prefix
init_sudo() {
    if [[ "$OS" == "macos" ]] || [[ $EUID -eq 0 ]]; then
        SUDO_PREFIX=""
    else
        SUDO_PREFIX="sudo"
    fi
}

# Get user home directory
get_user_home() {
    local user="$1"
    if [[ "$OS" == "macos" ]]; then
        eval echo "~$user"
    else
        getent passwd "$user" | cut -d: -f6
    fi
}

get_real_home() {
    local user="${SUDO_USER:-$(whoami)}"
    get_user_home "$user"
}

# Package Management
update_packages() {
    msg "Updating packages..."
    if [[ "$OS" == "macos" ]]; then
        brew update 2>/dev/null || true
        brew upgrade 2>/dev/null || true
    else
        $SUDO_PREFIX apt update && $SUDO_PREFIX apt upgrade -y
    fi
}

install_packages() {
    msg "Installing packages..."
    if [[ "$OS" == "macos" ]]; then
        brew install git nano zsh curl wget btop 2>/dev/null || true
    else
        $SUDO_PREFIX apt install -y git nano zsh curl wget btop
    fi
}

install_homebrew() {
    [[ "$OS" != "macos" ]] && return 0
    command -v brew &>/dev/null && return 0
    msg "Installing Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    [[ -d /opt/homebrew/bin ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
}

# File Operations
backup_file() {
    local file="$1" home="$(get_real_home)"
    [[ ! -f "$home/$file" ]] && return 0
    local backup_path="${BACKUP_DIR}/${file}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$(dirname "$backup_path")"
    cp -p "$home/$file" "$backup_path"
    msg "Backed up $file"
    [[ -n "${SUDO_USER:-}" ]] && chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$backup_path"
}

install_file() {
    local src="$1" dest="$2" home="$(get_real_home)"
    mkdir -p "$(dirname "$home/$dest")"
    mv -f "$src" "$home/$dest"
    chmod 644 "$home/$dest"
    [[ -n "${SUDO_USER:-}" ]] && chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$home/$dest"
    msg "Installed $dest"
}

download_file() {
    local url="${REPO_URL}/${1}" output="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL --max-time 30 "$url" -o "$output" || return 1
    elif command -v wget &>/dev/null; then
        wget -q --timeout=30 "$url" -O "$output" || return 1
    else
        err "Neither curl nor wget available"
        return 1
    fi
    [[ ! -s "$output" ]] && return 1
    return 0
}

# .nanorc Setup
setup_nanorc_include() {
    local home="$(get_real_home)" nanorc_file="$home/.nanorc" syntax_include=""

    if [[ "$OS" == "macos" ]]; then
        local brew_prefix
        brew_prefix=$(brew --prefix 2>/dev/null)
        [[ -d "$brew_prefix/share/nano" ]] && syntax_include="include \"$brew_prefix/share/nano/*.nanorc\""
        [[ -z "$syntax_include" ]] && [[ -d /opt/homebrew/share/nano ]] && syntax_include="include \"/opt/homebrew/share/nano/*.nanorc\""
        [[ -z "$syntax_include" ]] && [[ -d /usr/local/share/nano ]] && syntax_include="include \"/usr/local/share/nano/*.nanorc\""
    else
        [[ -d /usr/share/nano ]] && syntax_include="include \"/usr/share/nano/*.nanorc\""
    fi

    if [[ -n "$syntax_include" ]]; then
        local tmp=$(mktemp)
        { head -n 1 "$nanorc_file" 2>/dev/null; echo "$syntax_include"; echo ""; tail -n +2 "$nanorc_file" 2>/dev/null; } > "$tmp"
        mv -f "$tmp" "$nanorc_file"
        msg "Added nano include: $syntax_include"
    fi
}

# Root Symlinks
create_root_symlinks() {
    [[ -z "${SUDO_USER:-}" ]] && return 0
    [[ ! -d /root ]] && return 0
    [[ "$SUDO_USER" == "root" ]] && return 0
    local home="$(get_real_home)"
    msg "Creating root symlinks..."
    for file in .nanorc .p10k.zsh .zshrc .zshrc-profile; do
        [[ -f "$home/$file" ]] && ln -sf "$home/$file" "/root/$file"
    done
}

# Shell Configuration
change_shell() {
    local zsh_path="$(command -v zsh)"
    [[ -z "$zsh_path" ]] && return 1
    msg "Setting zsh as default shell..."

    # Add to /etc/shells
    if ! grep -qx "$zsh_path" /etc/shells 2>/dev/null; then
        $SUDO_PREFIX tee -a /etc/shells <<< "$zsh_path" > /dev/null
    fi

    # Change for user
    local user="${SUDO_USER:-$(whoami)}"
    [[ "$user" != "root" ]] && $SUDO_PREFIX chsh -s "$zsh_path" "$user" 2>/dev/null

    # Change for root (Linux only)
    [[ "$OS" == "linux" ]] && $SUDO_PREFIX chsh -s "$zsh_path" root 2>/dev/null
}

# Verification
verify() {
    local errors=0 home="$(get_real_home)"
    msg "Verifying..."
    for pkg in git nano zsh curl wget btop; do
        if command -v "$pkg" &>/dev/null; then
            msg "  [OK] $pkg"
        else
            err "  [FAIL] $pkg"
            errors=$((errors + 1))
        fi
    done
    for file in .nanorc .p10k.zsh .zshrc .zshrc-profile; do
        if [[ -f "$home/$file" ]]; then
            msg "  [OK] $file"
        else
            warn "  [MISS] $file"
        fi
    done
    [[ $errors -eq 0 ]] && msg "All verifications passed!" || warn "Verification completed with $errors errors"
}

# Main
main() {
    # Parse args
    for arg in "$@"; do
        case $arg in
            --force|-f) FORCE_MODE=true; msg "Force mode enabled" ;;
            --help|-h)  echo "Usage: $0 [--force]"; exit 0 ;;
        esac
    done

    msg "========================================"
    msg "Dotfiles Update/Install Script"
    msg "========================================"

    detect_os
    [[ "$OS" == "linux" && $EUID -ne 0 ]] && { err "Linux requires sudo. Run: sudo $0"; exit 1; }
    init_sudo

    local home="$(get_real_home)"
    local user="${SUDO_USER:-$(whoami)}"
    msg "Running as: $user | Home: $home"

    # Backup
    BACKUP_DIR="$home/.dotfiles_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    for f in .nanorc .p10k.zsh .zshrc .zshrc-profile; do
        [[ -f "$home/$f" ]] && backup_file "$f"
    done

    # Install packages
    install_homebrew
    update_packages
    install_packages

    # Download files
    local tmpdir="$(mktemp -d)"
    local failed=0

    msg "Downloading dotfiles..."
    for file in .nanorc .p10k.zsh .zshrc-profile; do
        download_file "$file" "$tmpdir/$file" || { err "Failed to download $file"; failed=1; }
    done

    # CRITICAL: .zshrc-profile must exist
    if [[ ! -f "$tmpdir/.zshrc-profile" ]]; then
        err "CRITICAL: .zshrc-profile download failed!"
        rm -rf "$tmpdir"
        exit 1
    fi

    # Install .zshrc-profile (always)
    install_file "$tmpdir/.zshrc-profile" ".zshrc-profile"

    # Install .nanorc (only if missing)
    if [[ -f "$tmpdir/.nanorc" ]]; then
        if [[ ! -f "$home/.nanorc" ]]; then
            install_file "$tmpdir/.nanorc" ".nanorc"
            setup_nanorc_include
        else
            msg "Keeping existing .nanorc"
            rm -f "$tmpdir/.nanorc"
        fi
    fi

    # Install .p10k.zsh (only if missing)
    if [[ -f "$tmpdir/.p10k.zsh" ]]; then
        if [[ ! -f "$home/.p10k.zsh" ]]; then
            install_file "$tmpdir/.p10k.zsh" ".p10k.zsh"
        else
            msg "Keeping existing .p10k.zsh"
            rm -f "$tmpdir/.p10k.zsh"
        fi
    fi

    # Install .zshrc (only if missing)
    if [[ ! -f "$home/.zshrc" ]]; then
        download_file ".zshrc" "$tmpdir/.zshrc" && install_file "$tmpdir/.zshrc" ".zshrc"
    else
        msg "Keeping existing .zshrc"
    fi

    rm -rf "$tmpdir"

    create_root_symlinks
    ask "Change default shell to zsh?" && change_shell
    verify

    # Cleanup
    msg "Cleaning up..."
    find "$home" -maxdepth 1 -type d -name ".dotfiles_backup_*" -mtime +7 -exec rm -rf {} \; 2>/dev/null || true
    [[ "$OS" == "linux" ]] && $SUDO_PREFIX apt autoremove -y 2>/dev/null && $SUDO_PREFIX apt autoclean 2>/dev/null
    [[ "$OS" == "macos" ]] && brew cleanup 2>/dev/null || true

    msg ""
    msg "========================================"
    msg "Update complete!"
    msg "Backup: $BACKUP_DIR"
    msg "Restart shell: exec zsh"
    msg "========================================"
}

main "$@"
