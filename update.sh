#!/usr/bin/env zsh
# =============================================================================
# Dotfiles Update/Install Script
# =============================================================================
# This script can be used for both initial installation and updates.
# It downloads the latest dotfiles from the repository and merges local
# customizations from existing .zshrc files.
#
# Usage:
#   ./update.sh          # Interactive mode (asks before replacing files)
#   ./update.sh --force  # Non-interactive mode (replaces files without asking)
# =============================================================================

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

readonly REPO_URL="https://raw.githubusercontent.com/Oculto54/Utils/main"
readonly DOTFILES=(".nanorc" ".p10k.zsh" ".zshrc-profile")
readonly ALL_DOTFILES=(".nanorc" ".p10k.zsh" ".zshrc" ".zshrc-profile")

# =============================================================================
# Global Variables
# =============================================================================
FORCE_MODE=false
OS=""
BACKUP_DIR=""

# =============================================================================
# Helper Functions
# =============================================================================

msg() {
    printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$1"
}

warn() {
    printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$1"
}

err() {
    printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$1" >&2
}

ask() {
    local question="$1"
    local default="${2:-y}"
    local yn

    if [[ "$FORCE_MODE" == true ]]; then
        return 0
    fi

    while true; do
        printf "%b[ASK]%b %s [y/n]: " "$CYAN" "$NC" "$question"
        read yn
        case $yn in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            "") [[ "$default" == "y" ]] && return 0 || return 1 ;;
            *) msg "Please answer yes or no." ;;
        esac
    done
}

ask_replace() {
    local file="$1"
    local action="${2:-replace}"

    if [[ "$FORCE_MODE" == true ]]; then
        return 0
    fi

    msg "File exists: $file"
    printf "  [R]eplace | [K]eep existing | [B]ackup and replace: "
    local choice
    read choice

    case "${choice:0:1}" in
        r|R) return 0 ;;
        k|K) return 2 ;;
        b|B) backup_file "$file" "manual"; return 0 ;;
        *) warn "Invalid choice, keeping existing file"; return 2 ;;
    esac
}

# =============================================================================
# OS Detection
# =============================================================================

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

# =============================================================================
# User Detection
# =============================================================================

get_real_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        echo "$SUDO_USER"
    else
        whoami
    fi
}

get_user_home() {
    local user="$1"
    if [[ "$OS" == "macos" ]]; then
        eval echo "~$user"
    else
        getent passwd "$user" | cut -d: -f6
    fi
}

get_real_home() {
    local user
    user=$(get_real_user)
    get_user_home "$user"
}

get_user_shell() {
    local user="$1"
    if [[ "$OS" == "macos" ]]; then
        dscl . -read /Users/"$user" UserShell 2>/dev/null | awk '{print $2}'
    else
        getent passwd "$user" | cut -d: -f7
    fi
}

# Check if we can run privileged commands (sudo available or running as root)
can_sudo() {
    if [[ $EUID -eq 0 ]]; then
        return 0  # Already root
    fi
    if [[ "$OS" == "macos" ]]; then
        # On macOS, we don't need sudo for brew
        return 0
    fi
    # On Linux, check if sudo is available
    command -v sudo &>/dev/null && sudo -n true 2>/dev/null
}

# Get the sudo prefix for commands
get_sudo_prefix() {
    if [[ "$OS" == "macos" ]]; then
        echo ""  # No sudo needed for brew
    elif [[ $EUID -eq 0 ]]; then
        echo ""  # Already root
    else
        echo "sudo"  # Need sudo
    fi
}

# =============================================================================
# Homebrew Installation (macOS only)
# =============================================================================

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

    if [[ -n "${SUDO_USER:-}" ]]; then
        su - "$SUDO_USER" -c 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    else
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi

    # Add to PATH for this session
    if [[ -d /opt/homebrew/bin ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -d /usr/local/bin ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    msg "Homebrew installed successfully"
}

# =============================================================================
# Package Management
# =============================================================================

update_packages() {
    msg "Updating package lists and upgrading packages..."

    local sudo_prefix
    sudo_prefix=$(get_sudo_prefix)

    if [[ "$OS" == "macos" ]]; then
        if command -v brew &>/dev/null; then
            if [[ -n "${SUDO_USER:-}" ]]; then
                su - "$SUDO_USER" -c "brew update && brew upgrade"
            else
                brew update && brew upgrade
            fi
        fi
    else
        $sudo_prefix apt update
        $sudo_prefix apt upgrade -y
    fi

    msg "Package update complete"
}

install_packages() {
    msg "Installing required packages: git, nano, zsh, curl, wget, btop..."

    local sudo_prefix
    sudo_prefix=$(get_sudo_prefix)

    if [[ "$OS" == "macos" ]]; then
        if [[ -n "${SUDO_USER:-}" ]]; then
            su - "$SUDO_USER" -c "brew install git nano zsh curl wget btop"
        else
            brew install git nano zsh curl wget btop
        fi
    else
        $sudo_prefix apt install -y git nano zsh curl wget btop
    fi

    msg "Packages installed successfully"
}

# =============================================================================
# File Operations
# =============================================================================

backup_file() {
    local file="$1"
    local reason="${2:-auto}"
    local home
    home=$(get_real_home)

    if [[ ! -f "$home/$file" ]]; then
        return 0
    fi

    local backup_path="${BACKUP_DIR}/${file}_$(date +%Y%m%d_%H%M%S)"

    # Create parent directory if needed
    mkdir -p "$(dirname "$backup_path")"

    cp -p "$home/$file" "$backup_path"
    msg "Backed up $file -> $backup_path (reason: $reason)"

    # Fix ownership
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$backup_path"
    fi
}

backup_dotfiles() {
    local home
    home=$(get_real_home)

    msg "Backing up existing dotfiles..."

    for file in $ALL_DOTFILES; do
        if [[ -f "$home/$file" ]]; then
            backup_file "$file" "pre-update"
        fi
    done

    msg "Backup complete"
}

download_file() {
    local filename="$1"
    local output="$2"
    local url="${REPO_URL}/${filename}"

    msg "Downloading $filename..."

    if command -v curl &>/dev/null; then
        if ! curl -fsSL --max-time 30 "$url" -o "$output"; then
            err "Failed to download $filename from $url"
            return 1
        fi
    elif command -v wget &>/dev/null; then
        if ! wget -q --timeout=30 "$url" -O "$output"; then
            err "Failed to download $filename from $url"
            return 1
        fi
    else
        err "Neither curl nor wget is available"
        return 1
    fi

    if [[ ! -s "$output" ]]; then
        err "Downloaded file $filename is empty"
        rm -f "$output"
        return 1
    fi

    msg "Downloaded $filename successfully"
    return 0
}

# =============================================================================
# .zshrc Merge Logic
# =============================================================================

extract_local_section() {
    local existing_zshrc="$1"
    local temp_file
    temp_file=$(mktemp)

    # Look for the "Local Customizations" section
    if grep -q "^# =============================================================================" "$existing_zshrc" 2>/dev/null; then
        # Find and extract everything from "Local Customizations" marker onwards
        local local_section
        local_section=$(awk '/^# Local Customizations$/,0' "$existing_zshrc")

        if [[ -n "$local_section" ]]; then
            cat > "$temp_file" <<'HEADER'
# =============================================================================
# Local Zsh Configuration
# =============================================================================
#
# This is the LOCAL configuration file that is managed locally on your machine.
# It loads the shared configuration from .zshrc-profile, which contains all
# the actual shell settings, plugins, aliases, and prompt configuration.
#
# .zshrc-profile is downloaded/updated separately and should not be edited locally.
# Add any LOCAL customizations (PATH, aliases, variables) in the section below.
#
# =============================================================================

# Load the shared profile configuration
source "${HOME}/.zshrc-profile"

HEADER
            echo "$local_section" >> "$temp_file"
            echo "$temp_file"
            return 0
        fi
    fi

    rm -f "$temp_file"
    return 1
}

merge_zshrc() {
    local home
    home=$(get_real_home)
    local existing_zshrc="$home/.zshrc"
    local new_dummy_zshrc="$home/.zshrc.new"
    local temp_merged

    # Check if existing .zshrc has local customizations
    temp_merged=$(extract_local_section "$existing_zshrc")

    if [[ -n "$temp_merged" ]] && [[ -s "$temp_merged" ]]; then
        msg "Found local customizations in existing .zshrc"
        mv "$temp_merged" "$new_dummy_zshrc"
        msg "Merged local customizations into new .zshrc"
        return 0
    else
        # No local section found, just remove temp file
        rm -f "$temp_merged"
        return 1
    fi
}

# =============================================================================
# .nanorc Setup
# =============================================================================

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
        if command -v brew &>/dev/null; then
            local brew_prefix
            brew_prefix=$(brew --prefix)
            if [[ -d "$brew_prefix/share/nano" ]]; then
                syntax_include="include \"$brew_prefix/share/nano/*.nanorc\""
            fi
        fi
        if [[ -z "$syntax_include" ]]; then
            for dir in /opt/homebrew/share/nano /usr/local/share/nano /opt/local/share/nano; do
                if [[ -d "$dir" ]]; then
                    syntax_include="include \"$dir/*.nanorc\""
                    break
                fi
            done
        fi
    else
        if [[ -d /usr/share/nano ]]; then
            syntax_include="include \"/usr/share/nano/*.nanorc\""
        fi
    fi

    # Insert the include at line 2
    if [[ -n "$syntax_include" ]]; then
        {
            head -n 1 "$nanorc_file" 2>/dev/null || echo ""
            echo "$syntax_include"
            echo ""
            tail -n +2 "$nanorc_file" 2>/dev/null || true
        } > "$temp_file"
        mv -f "$temp_file" "$nanorc_file"
        msg "Added syntax include at line 2: $syntax_include"
    else
        msg "No nano syntax directory found, skipping include"
        rm -f "$temp_file"
    fi

    # Fix ownership
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$nanorc_file"
    fi
    chmod 644 "$nanorc_file"

    msg ".nanorc configured for $OS"
}

# =============================================================================
# Root Symlinks
# =============================================================================

create_root_symlinks() {
    # Skip if not running under sudo
    if [[ -z "${SUDO_USER:-}" ]]; then
        msg "Not running under sudo, skipping root symlinks"
        return 0
    fi

    # Skip if /root doesn't exist
    if [[ ! -d "/root" ]]; then
        msg "/root directory not found, skipping root symlinks"
        return 0
    fi

    # Skip if running as root user
    if [[ "$SUDO_USER" == "root" ]]; then
        msg "Running as root user, skipping root symlinks"
        return 0
    fi

    local user_home
    user_home=$(get_real_home)

    msg "Creating root symlinks..."

    local linked=0
    for file in $ALL_DOTFILES; do
        if [[ -f "$user_home/$file" ]]; then
            ln -sf "$user_home/$file" "/root/$file"
            msg "Created symlink: /root/$file -> $user_home/$file"
            linked=$((linked + 1))
        fi
    done

    if [[ $linked -gt 0 ]]; then
        msg "Created $linked root symlinks"
    else
        warn "No root symlinks created (files may be missing)"
    fi
}

# =============================================================================
# Shell Configuration
# =============================================================================

change_shell() {
    local zsh_path
    zsh_path=$(command -v zsh)

    if [[ -z "$zsh_path" ]]; then
        err "zsh not found in PATH"
        return 1
    fi

    local sudo_prefix
    sudo_prefix=$(get_sudo_prefix)

    msg "Changing default shell to zsh ($zsh_path)..."

    # Add zsh to /etc/shells if not present
    if ! grep -qx "$zsh_path" /etc/shells 2>/dev/null; then
        $sudo_prefix sh -c "echo '$zsh_path' >> /etc/shells"
        msg "Added $zsh_path to /etc/shells"
    fi

    # Change shell for the real user
    local real_user
    real_user=$(get_real_user)

    if [[ "$real_user" != "root" ]]; then
        local current_shell
        current_shell=$(get_user_shell "$real_user")
        if [[ "$current_shell" != "$zsh_path" ]]; then
            $sudo_prefix chsh -s "$zsh_path" "$real_user"
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
            $sudo_prefix chsh -s "$zsh_path" root
            msg "Changed shell for root to zsh"
        else
            msg "Shell for root is already zsh"
        fi
    fi
}

# =============================================================================
# Verification
# =============================================================================

verify_installation() {
    local home
    home=$(get_real_home)

    msg "Verifying installation..."

    local errors=0

    # Check packages
    for pkg in git nano zsh curl wget btop; do
        if command -v "$pkg" &>/dev/null; then
            msg "  [OK] $pkg installed"
        else
            err "  [FAIL] $pkg not found"
            errors=$((errors + 1))
        fi
    done

    # Check dotfiles
    for file in $ALL_DOTFILES; do
        if [[ -f "$home/$file" ]]; then
            msg "  [OK] $file installed"
        else
            warn "  [SKIP] $file not found (optional)"
        fi
    done

    if [[ $errors -eq 0 ]]; then
        msg "All verifications passed!"
    else
        warn "Verification completed with $errors errors"
    fi
}

# =============================================================================
# Main Download and Install Logic
# =============================================================================

download_and_install_dotfiles() {
    local home
    home=$(get_real_home)
    local temp_dir
    temp_dir=$(mktemp -d)
    local has_errors=0

    msg "Downloading dotfiles from repository..."

    for file in $DOTFILES; do
        local temp_file="$temp_dir/$file"

        # Download to temp location
        if ! download_file "$file" "$temp_file"; then
            has_errors=1
            continue
        fi

        # Check if file exists and ask about replacement
        if [[ -f "$home/$file" ]]; then
            if ! ask_replace "$file" "replace"; then
                msg "Skipped $file"
                rm -f "$temp_file"
                continue
            fi
        fi

        # Move to home directory
        mv -f "$temp_file" "$home/$file"

        # Set correct ownership
        if [[ -n "${SUDO_USER:-}" ]]; then
            chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$home/$file"
        fi
        chmod 644 "$home/$file"

        msg "Installed $file"
    done

    # Handle .zshrc (the dummy/local one)
    handle_zshrc() {
        local existing_zshrc="$home/.zshrc"
        local new_zshrc="$temp_dir/.zshrc"

        # Download the standard .zshrc to temp
        if ! download_file ".zshrc" "$new_zshrc"; then
            # If download fails, warn but continue
            warn "Could not download standard .zshrc, skipping"
            return 1
        fi

        # Check if existing .zshrc exists - we need to merge local customizations
        if [[ -f "$existing_zshrc" ]]; then
            msg "Existing .zshrc found - checking for local customizations..."

            # Backup existing before replacing
            backup_file ".zshrc" "pre-replace"

            # Try to merge local sections
            local temp_merged
            temp_merged=$(extract_local_section "$existing_zshrc")

            if [[ -n "$temp_merged" ]] && [[ -s "$temp_merged" ]]; then
                msg "Found local customizations - merging into new .zshrc..."
                mv "$temp_merged" "$new_zshrc"
            else
                warn "No local customizations found in existing .zshrc"
                rm -f "$temp_merged"
            fi
        fi

        # ALWAYS install the new dummy .zshrc because it sources .zshrc-profile
        # This is critical - without it, .zshrc-profile is never loaded
        mv -f "$new_zshrc" "$home/.zshrc"

        # Set correct ownership
        if [[ -n "${SUDO_USER:-}" ]]; then
            chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$home/.zshrc"
        fi
        chmod 644 "$home/.zshrc"

        msg "Installed .zshrc (sources .zshrc-profile)"
        return 0
    }

    handle_zshrc

    # Cleanup temp directory
    rm -rf "$temp_dir"

    if [[ $has_errors -eq 1 ]]; then
        warn "Some files failed to download"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Parse arguments
    for arg in "$@"; do
        case $arg in
            --force|-f)
                FORCE_MODE=true
                msg "Running in force mode (no prompts)"
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo "  --force, -f    Run without prompts (auto-answer yes)"
                echo "  --help, -h     Show this help message"
                exit 0
                ;;
            *)
                ;;
        esac
    done

    msg "========================================"
    msg "Dotfiles Update/Install Script"
    msg "========================================"

    # Step 1: Detect OS
    detect_os

    # Check sudo access on Linux
    if [[ "$OS" == "linux" ]] && ! can_sudo; then
        err "This script requires sudo privileges on Linux."
        err "Please run with: sudo $0"
        exit 1
    fi

    # Step 2: Detect user context
    local real_user
    real_user=$(get_real_user)
    local real_home
    real_home=$(get_real_home)

    msg "Running as user: $real_user"
    msg "Home directory: $real_home"

    if [[ $EUID -eq 0 ]]; then
        msg "Running as root"
    fi

    # Step 3: Create backup directory
    BACKUP_DIR="$real_home/.dotfiles_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    # Step 4: Backup existing dotfiles
    backup_dotfiles

    # Step 5: Install Homebrew (macOS only)
    install_homebrew

    # Step 6: Update packages
    update_packages

    # Step 7: Install packages
    install_packages

    # Step 8: Download and install dotfiles
    download_and_install_dotfiles

    # Step 9: Setup .nanorc with correct path
    setup_nanorc

    # Step 10: Create root symlinks
    create_root_symlinks

    # Step 11: Change shell to zsh
    if ask "Change default shell to zsh?" "y"; then
        change_shell
    fi

    # Step 12: Verification
    verify_installation

    # Cleanup
    msg "Cleaning up backup files older than 7 days..."
    find "$real_home" -maxdepth 1 -type d -name ".dotfiles_backup_*" -mtime +7 -exec rm -rf {} \; 2>/dev/null || true

    # Linux apt cleanup
    if [[ "$OS" == "linux" ]]; then
        local sudo_prefix
        sudo_prefix=$(get_sudo_prefix)
        msg "Running apt autoremove and autoclean..."
        $sudo_prefix apt autoremove -y 2>/dev/null || true
        $sudo_prefix apt autoclean 2>/dev/null || true
    fi

    msg ""
    msg "========================================"
    msg "Update complete!"
    msg "========================================"
    msg ""
    msg "Backup directory: $BACKUP_DIR"
    msg ""
    msg "NOTE: You may need to restart your shell or"
    msg "run 'exec zsh' to apply all changes."
    msg ""
}

# Run main
main "$@"
