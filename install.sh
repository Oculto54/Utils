#!/bin/bash
set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# GitHub repository URL
readonly REPO_URL="https://raw.githubusercontent.com/Oculto54/teste/main"

# Functions for colored output
msg() {
    printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$1"
}

warn() {
    printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$1"
}

err() {
    printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$1" >&2
}

# Check if running as root/sudo
check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run with sudo or as root"
        exit 1
    fi
    msg "Running with root privileges"
}

# Detect operating system
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        msg "Detected OS: macOS"
    elif [[ "$OSTYPE" == "linux-gnu"* ]] || [[ -f /etc/debian_version ]]; then
        OS="linux"
        msg "Detected OS: Linux"
    else
        err "Unsupported operating system: $OSTYPE"
        exit 1
    fi
}

# Install Homebrew on macOS if not present
install_homebrew() {
    if [[ "$OS" != "macos" ]]; then
        return 0
    fi
    
    if command -v brew &>/dev/null; then
        msg "Homebrew already installed"
        return 0
    fi
    
    msg "Installing Homebrew..."
    export HOMEBREW_NO_INSTALL_FROM_API=1
    export HOMEBREW_NO_AUTO_UPDATE=1
    
    # Run Homebrew installer as the SUDO_USER
    if [[ -n "${SUDO_USER:-}" ]]; then
        su - "$SUDO_USER" -c 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    else
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    
    # Add Homebrew to PATH for this session
    if [[ -d /opt/homebrew/bin ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -d /usr/local/bin ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    
    msg "Homebrew installed successfully"
}

# Update and upgrade packages
update_packages() {
    msg "Updating and upgrading packages..."
    
    if [[ "$OS" == "macos" ]]; then
        if command -v brew &>/dev/null; then
            if [[ -n "${SUDO_USER:-}" ]]; then
                su - "$SUDO_USER" -c "brew update && brew upgrade"
            else
                brew update && brew upgrade
            fi
        fi
    else
        apt-get update
        apt-get upgrade -y
    fi
    
    msg "Packages updated successfully"
}

# Install required packages
install_packages() {
    msg "Installing packages: git, nano, zsh, curl, wget, btop..."
    
    if [[ "$OS" == "macos" ]]; then
        if [[ -n "${SUDO_USER:-}" ]]; then
            su - "$SUDO_USER" -c "brew install git nano zsh curl wget btop"
        else
            brew install git nano zsh curl wget btop
        fi
    else
        apt-get install -y git nano zsh curl wget btop
    fi
    
    msg "Packages installed successfully"
}

# Get real user (SUDO_USER or current user)
get_real_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        echo "$SUDO_USER"
    else
        whoami
    fi
}

# Cross-platform: Get user home directory
get_user_home() {
    local user="$1"
    if [[ "$OS" == "macos" ]]; then
        eval echo "~$user"
    else
        getent passwd "$user" | cut -d: -f6
    fi
}

# Cross-platform: Get user shell
get_user_shell() {
    local user="$1"
    if [[ "$OS" == "macos" ]]; then
        dscl . -read /Users/"$user" UserShell 2>/dev/null | awk '{print $2}'
    else
        getent passwd "$user" | cut -d: -f7
    fi
}

# Get real home directory
get_real_home() {
    local user
    user=$(get_real_user)
    get_user_home "$user"
}

# Backup existing dotfiles
backup_dotfiles() {
    local home
    home=$(get_real_home)
    
    # Validate home directory
    if [[ -z "$home" ]]; then
        err "Could not determine home directory"
        exit 1
    fi
    
    if [[ ! -d "$home" ]]; then
        err "Home directory does not exist: $home"
        exit 1
    fi
    
    local backup_dir="$home/.dotfiles_backup_$(date +%Y%m%d_%H%M%S)"

    msg "Backing up existing dotfiles..."
    
    local files_to_backup=(".p10k.zsh" ".nanorc" ".zshrc")
    local backed_up=0
    
    mkdir -p "$backup_dir"
    
    for file in "${files_to_backup[@]}"; do
        if [[ -f "$home/$file" ]]; then
            cp -p "$home/$file" "$backup_dir/$file"
            backed_up=$((backed_up + 1))
            msg "Backed up: $file"
        fi
    done
    
    if [[ $backed_up -gt 0 ]]; then
        # Fix ownership if running as sudo
        if [[ -n "${SUDO_USER:-}" ]]; then
            chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$backup_dir"
        fi
        msg "Backup complete: $backup_dir ($backed_up files)"
    else
        rmdir "$backup_dir" 2>/dev/null || true
        msg "No existing dotfiles to backup"
    fi
}

# Download file from URL
download_file() {
    local url="$1"
    local output="$2"
    
    if command -v curl &>/dev/null; then
        curl -fsSL --max-time 30 "$url" -o "$output"
    elif command -v wget &>/dev/null; then
        wget -q --timeout=30 "$url" -O "$output"
    else
        err "Neither curl nor wget is available"
        exit 1
    fi
}

# Download dotfiles from GitHub
download_dotfiles() {
    local home
    home=$(get_real_home)
    local temp_dir
    temp_dir=$(mktemp -d)
    
    msg "Downloading dotfiles from GitHub..."
    
    # Download each file
    local files=(".zshrc" ".p10k.zsh" ".nanorc")
    for file in "${files[@]}"; do
        local temp_file="$temp_dir/$file"
        local url="$REPO_URL/$file"
        
        msg "Downloading $file..."
        if download_file "$url" "$temp_file"; then
            # Verify file is not empty
            if [[ -s "$temp_file" ]]; then
                msg "Successfully downloaded $file"
            else
                err "Downloaded file $file is empty"
                exit 1
            fi
        else
            err "Failed to download $file from $url"
            exit 1
        fi
    done
    
    # Move files to home directory
    for file in "${files[@]}"; do
        mv -f "$temp_dir/$file" "$home/$file"
        # Set correct ownership
        if [[ -n "${SUDO_USER:-}" ]]; then
            chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$home/$file"
        fi
        chmod 644 "$home/$file"
    done
    
    # Cleanup temp directory
    rm -rf "$temp_dir"
    
    msg "All dotfiles downloaded successfully"
}

# Prepend correct nano syntax include to .nanorc
setup_nanorc() {
    local home
    home=$(get_real_home)
    local nanorc_file="$home/.nanorc"
    local temp_file
    temp_file=$(mktemp)
    
    msg "Setting up cross-platform .nanorc..."
    
    # Determine the correct syntax directory based on OS
    local syntax_include=""
    if [[ "$OS" == "macos" ]]; then
        # Check common macOS nano syntax locations
        for dir in /opt/homebrew/share/nano /usr/local/share/nano /opt/local/share/nano; do
            if [[ -d "$dir" ]]; then
                syntax_include="include \"$dir/*.nanorc\""
                break
            fi
        done
    else
        # Linux path
        if [[ -d /usr/share/nano ]]; then
            syntax_include="include \"/usr/share/nano/*.nanorc\""
        fi
    fi
    
    # Prepend the include line to the existing .nanorc
    if [[ -n "$syntax_include" ]]; then
        # Create temp file with include line first, then original content
        echo "$syntax_include" > "$temp_file"
        echo "" >> "$temp_file"
        # Append original .nanorc content if it exists
        if [[ -f "$nanorc_file" ]]; then
            cat "$nanorc_file" >> "$temp_file"
        fi
        
        # Replace original with updated version
        mv -f "$temp_file" "$nanorc_file"
        msg "Added syntax include: $syntax_include"
    else
        msg "No nano syntax directory found, skipping include"
    fi
    
    # Fix ownership
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$nanorc_file"
    fi
    chmod 644 "$nanorc_file"
    
    msg ".nanorc configured for $OS"
}

# Create root symlinks
create_root_symlinks() {
    # Only create root symlinks if:
    # 1. Running as sudo (SUDO_USER is set)
    # 2. /root directory exists
    # 3. Not already running as root user
    
    if [[ -z "${SUDO_USER:-}" ]]; then
        msg "Not running under sudo, skipping root symlinks"
        return 0
    fi
    
    if [[ ! -d "/root" ]]; then
        msg "/root directory not found, skipping root symlinks"
        return 0
    fi
    
    if [[ "$SUDO_USER" == "root" ]]; then
        msg "Running as root user, skipping root symlinks"
        return 0
    fi
    
    local user_home
    user_home=$(get_real_home)
    
    msg "Creating root symlinks..."
    
    local files=(".zshrc" ".p10k.zsh" ".nanorc")
    local created=0
    
    for file in "${files[@]}"; do
        if [[ -f "$user_home/$file" ]]; then
            ln -sf "$user_home/$file" "/root/$file"
            created=$((created + 1))
            msg "Created symlink: /root/$file -> $user_home/$file"
        fi
    done
    
    if [[ $created -gt 0 ]]; then
        msg "Created $created root symlinks"
    else
        warn "No root symlinks created (files may be missing)"
    fi
}

# Change default shell to zsh
change_shell() {
    local zsh_path
    zsh_path=$(command -v zsh)
    
    if [[ -z "$zsh_path" ]]; then
        err "zsh not found in PATH"
        exit 1
    fi
    
    msg "Changing default shell to zsh..."
    
    # Add zsh to /etc/shells if not present
    if ! grep -qx "$zsh_path" /etc/shells 2>/dev/null; then
        echo "$zsh_path" >> /etc/shells
        msg "Added $zsh_path to /etc/shells"
    fi
    
    # Change shell for the real user
    local real_user
    real_user=$(get_real_user)
    
    if [[ "$real_user" != "root" ]]; then
        local current_shell
        current_shell=$(get_user_shell "$real_user")
        if [[ "$current_shell" != "$zsh_path" ]]; then
            chsh -s "$zsh_path" "$real_user"
            msg "Changed shell for $real_user to zsh"
        else
            msg "Shell for $real_user is already zsh"
        fi
    fi
    
    # Change shell for root (only on Linux)
    if [[ "$OS" == "linux" ]]; then
        local root_shell
        root_shell=$(get_user_shell root)
        if [[ "$root_shell" != "$zsh_path" ]]; then
            chsh -s "$zsh_path" root
            msg "Changed shell for root to zsh"
        else
            msg "Shell for root is already zsh"
        fi
    fi
}

# Cleanup
cleanup() {
    msg "Cleaning up..."
    
    if [[ "$OS" == "macos" ]]; then
        if [[ -n "${SUDO_USER:-}" ]] && command -v brew &>/dev/null; then
            su - "$SUDO_USER" -c "brew cleanup" || true
        elif command -v brew &>/dev/null; then
            brew cleanup || true
        fi
    else
        apt-get autoremove -y || true
        apt-get autoclean || true
    fi
    
    msg "Cleanup complete"
}

# Verify installation
verify_installation() {
    local home
    home=$(get_real_home)
    
    msg "Verifying installation..."
    
    local errors=0
    
    # Check packages
    for pkg in git nano zsh curl wget btop; do
        if command -v "$pkg" &>/dev/null; then
            msg "✓ $pkg installed"
        else
            err "✗ $pkg not found"
            errors=$((errors + 1))
        fi
    done
    
    # Check dotfiles
    for file in ".zshrc" ".p10k.zsh" ".nanorc"; do
        if [[ -f "$home/$file" ]]; then
            msg "✓ $file installed"
        else
            err "✗ $file not found"
            errors=$((errors + 1))
        fi
    done
    
    if [[ $errors -eq 0 ]]; then
        msg "All verifications passed!"
    else
        warn "Verification completed with $errors errors"
    fi
}

# Main function
main() {
    msg "Starting dotfiles installation..."
    
    # Step 1: Checks
    check_sudo
    detect_os
    
    # Step 2: Package management
    install_homebrew
    update_packages
    install_packages
    
    # Step 3: Dotfiles
    backup_dotfiles
    download_dotfiles
    setup_nanorc
    
    # Step 4: Configuration
    create_root_symlinks
    change_shell
    
    # Step 5: Verification and cleanup
    verify_installation
    cleanup
    
    # Step 6: Completion
    msg "========================================"
    msg "Installation complete!"
    msg "========================================"
    msg "Starting zsh session..."
    msg ""
    msg "Note: You may need to log out and back in"
    msg "for the shell change to take full effect."
    msg ""
    
    # Start zsh for the real user
    local real_user
    real_user=$(get_real_user)
    local home
    home=$(get_real_home)
    
    if [[ "$real_user" != "root" ]] && [[ -n "${SUDO_USER:-}" ]]; then
        # Switch to the user and start zsh
        su - "$SUDO_USER" -c "cd && exec zsh -l"
    else
        # Start zsh directly
        cd "$home" && exec zsh -l
    fi
}

# Run main function
main "$@"
