#!/bin/bash

set -euo pipefail

readonly PLATFORM=$(uname -s)

[[ -t 1 ]] && { readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' NC='\033[0m'; } || { readonly RED='' GREEN='' YELLOW='' BLUE='' NC=''; }

msg() {
    local color_name="${1^^}" text="${*:2}"
    local color="${!color_name:-}"
    printf "%b[%s]%b %s\n" "$color" "$1" "$NC" "$text"
}
err() {
    printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*" >&2
}

# Cross-platform user info functions
get_user_info() {
    local user="$1" field="$2"
    if [[ "$PLATFORM" == "Darwin" ]]; then
        local key; [[ "$field" == "home" ]] && key="NFSHomeDirectory" || key="UserShell"
        dscl . -read "/Users/$user" "$key" 2>/dev/null | awk '{print $2}'
    else
        local col; [[ "$field" == "home" ]] && col=6 || col=7
        getent passwd "$user" 2>/dev/null | cut -d: -f"$col"
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

# Check which symlinks need to be created
check_symlinks_status() {
    local -a files=(".zshrc" ".p10k.zsh" ".nanorc")
    local missing=0
    local symlink_needed=0

    for f in "${files[@]}"; do
        local target="$REAL_HOME/$f"
        local symlink="/root/$f"

        # Check if target file exists
        if [[ ! -f "$target" ]]; then
            ((missing++))
            continue
        fi

        # Check if symlink needs to be created
        if [[ ! -L "$symlink" ]]; then
            ((symlink_needed++))
        fi
    done

    # Return codes:
    # 0 = all complete (no missing files, no symlinks needed)
    # 1 = missing files (need Phase 2)
    # 2 = files exist but symlinks needed
    [[ $missing -gt 0 ]] && return 1
    [[ $symlink_needed -gt 0 ]] && return 2
    return 0
}

# Show Phase 1 completion message
show_phase1_message() {
    msg GREEN ""
    msg GREEN "=========================================="
    msg GREEN "Phase 1 Complete!"
    msg GREEN "=========================================="
    msg GREEN ""
    msg GREEN "Next steps:"
    msg GREEN " 1. Run: exec zsh -l"
    msg GREEN " 2. Run: p10k configure"
    msg GREEN " 3. Run this script again to complete setup"
    msg GREEN ""
    msg YELLOW "Note: Marker file ~/.phase1-marker created"
    msg YELLOW "      (This tracks your setup progress)"
    local last_backup
    last_backup=$(ls -d "$REAL_HOME/.dotfiles_backup_"* 2>/dev/null | tail -1)
    [[ -n "$last_backup" ]] && msg GREEN "Backup: $last_backup"
}

# Show Phase 2 completion message
show_phase2_complete() {
    msg GREEN ""
    msg GREEN "=========================================="
    msg GREEN "Phase 2 Complete!"
    msg GREEN "=========================================="
    msg GREEN ""
    msg GREEN "Root symlinks created successfully!"
    msg GREEN "All dotfiles are now properly linked to /root/"
    msg GREEN ""
    msg GREEN "You're all set! Log out and back in."
}

# Show normal completion message
show_complete_message() {
    msg GREEN ""
    msg GREEN "=========================================="
    msg GREEN "Installation Complete!"
    msg GREEN "=========================================="
    msg GREEN ""
    msg GREEN "Everything is configured and ready!"
    msg GREEN ""
    msg GREEN "Next steps:"
    msg GREEN " 1. Log out and log back in"
    msg GREEN " 2. Run: zsh"
    msg GREEN ""
    local last_backup
    last_backup=$(ls -d "$REAL_HOME/.dotfiles_backup_"* 2>/dev/null | tail -1)
    [[ -n "$last_backup" ]] && msg GREEN "Backup: $last_backup"
}

cleanup() {
    local c=$?; [[ $c -ne 0 ]] && err "Installation failed."
    [[ -f "${TEMP_DIR:-}/.zshrc.tmp" ]] && rm -f "$TEMP_DIR/.zshrc.tmp"
    exit $c
}
trap cleanup EXIT

check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run with sudo or as root (EUID=$EUID)"
        exit 1
    fi
    [[ -z "${SUDO_USER:-}" ]] && return 0

    # Validate username format while preventing path traversal
    [[ "$SUDO_USER" == *".."* ]] && { err "SUDO_USER contains path traversal: ${SUDO_USER}"; exit 1; }
    [[ "$SUDO_USER" == */* ]] && { err "SUDO_USER contains path separator: ${SUDO_USER}"; exit 1; }
    [[ "$SUDO_USER" =~ ^\.|\. ]] && { err "SUDO_USER has leading/trailing dot: ${SUDO_USER}"; exit 1; }
    [[ ! "$SUDO_USER" =~ ^[a-zA-Z0-9._-]+$ ]] && { err "Invalid SUDO_USER format: ${SUDO_USER}"; exit 1; }
    ! id "$SUDO_USER" &>/dev/null && { err "User not found: ${SUDO_USER}"; exit 1; }
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
    local -a packages=("$@")

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

    case "$PKG_MGR" in
        brew)
            case "$action" in
                update) su - "$SUDO_USER" -c 'brew update && brew upgrade' ;;
                install) su - "$SUDO_USER" -c "brew install --quiet ${safe_pkgs}" ;;
                cleanup) su - "$SUDO_USER" -c 'brew cleanup --prune=all && brew autoremove' ;;
            esac ;;
        apt)
            case "$action" in
                update) apt-get update && apt-get upgrade -y ;;
                install) apt-get install -y "$@" ;;
                cleanup) apt-get autoremove -y && apt-get autoclean ;;
            esac ;;
        dnf|yum)
            case "$action" in
                update) "$PKG_MGR" update -y ;;
                install) "$PKG_MGR" install -y "$@" ;;
                cleanup) "$PKG_MGR" autoremove -y ;;
            esac ;;
        pacman)
            case "$action" in
                update) pacman -Syu --noconfirm ;;
                install) pacman -S --noconfirm "$@" ;;
                cleanup) pacman -Qdtq 2>/dev/null | pacman -Rns --noconfirm - 2>/dev/null; pacman -Sc --noconfirm ;;
            esac ;;
        zypper)
            case "$action" in
                update) zypper update -y ;;
                install) zypper install -y "$@" ;;
                cleanup) zypper packages --unneeded | awk -F'|' 'NR>2 && $3 ~ /[^[:space:]]/ {print $3}' | xargs -r zypper remove -y 2>/dev/null; zypper clean ;;
            esac ;;
    esac
}

update_packages() { msg GREEN "Updating packages..."; run_pkg update; }

install_packages() { msg GREEN "Installing packages (git, zsh, curl, wget)..."; run_pkg install git zsh curl wget; }

backup_dotfiles() {
    msg GREEN "Backing up dotfiles..."

    local dir="$REAL_HOME/.dotfiles_backup_$(date +%Y%m%d_%H%M%S)"

    mkdir -p "$dir" || { err "Failed to create backup directory"; exit 1; }
    
    local files=(".bashrc" ".bash_profile" ".profile" ".zshrc" ".zprofile" ".zlogin" ".zlogout")
    local to_backup=()
    for f in "${files[@]}"; do [[ -f "$REAL_HOME/$f" ]] && to_backup+=("$f"); done
    
    [[ ${#to_backup[@]} -eq 0 ]] && { msg GREEN "No dotfiles to backup"; rmdir "$dir" 2>/dev/null || true; return 0; }
    
    tar -czf "$dir/dotfiles.tar.gz" -C "$REAL_HOME" "${to_backup[@]}" 2>/dev/null && msg GREEN "Backed up ${#to_backup[@]} file(s)" || msg YELLOW "Some files could not be backed up"
    set_ownership "$dir" -R || return 1
    msg GREEN "Backup complete: $dir"
}

# Download file using curl or wget
download_file() {
    local url="$1" output="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL --max-time 30 --retry 3 "$url" -o "$output" 2>/dev/null && return 0
    fi
    if command -v wget &>/dev/null; then
        wget -q --timeout=30 --tries=3 "$url" -O "$output" 2>/dev/null && return 0
    fi
    return 1
}

download_zshrc() {
    msg GREEN "Downloading .zshrc configuration..."
    local base_url="https://raw.githubusercontent.com/Oculto54/Utils/main"
    local url="${base_url}/.zshrc"
    local checksum_url="${base_url}/.zshrc.sha256"
    local tmp="$TEMP_DIR/.zshrc.tmp"
    local checksum_tmp="$TEMP_DIR/.zshrc.sha256.tmp"
    local target="$REAL_HOME/.zshrc"

    download_file "$url" "$tmp" || { err "Failed to download .zshrc"; exit 1; }
    download_file "$checksum_url" "$checksum_tmp" || { err "Failed to download checksum"; rm -f "$tmp"; exit 1; }

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
    [[ "$REAL_HOME" == "/root" ]] && { msg GREEN "Skipping root symlinks (home is /root)"; return 0; }

    # Check if all symlinks already exist
    local -a files=(".zshrc" ".p10k.zsh" ".nanorc")
    local all_exist=1
    for f in "${files[@]}"; do
        [[ -L "/root/$f" ]] || { all_exist=0; break; }
    done
    [[ $all_exist -eq 1 ]] && { msg GREEN "Root symlinks already configured"; return 0; }

    msg GREEN "Creating symbolic links for root..."

    local target
    local -a created=()
    local -a skipped=()
    local -a not_found=()

    for f in "${files[@]}"; do
        target="$REAL_HOME/$f"

        # Security: Verify target is within REAL_HOME (prevent traversal)
        [[ "$target" != "$REAL_HOME"/* ]] && { err "Security: Target $target outside home directory"; continue; }

        # Only symlink existing regular files
        if [[ -f "$target" ]]; then
            # Verify file is owned by SUDO_USER
            local file_owner
            file_owner=$(stat -c '%U' "$target" 2>/dev/null) || file_owner=$(stat -f '%Su' "$target" 2>/dev/null)
            if [[ "$file_owner" != "$SUDO_USER" ]]; then
                err "Security: $target not owned by $SUDO_USER (owner: $file_owner)"
                skipped+=("$f")
                continue
            fi

            # Create symlink
            ln -sf "$target" "/root/$f" && created+=("$f")
        else
            not_found+=("$f")
        fi
    done

    # Report results
    [[ ${#created[@]} -gt 0 ]] && msg GREEN "Created: ${created[*]}"
    [[ ${#skipped[@]} -gt 0 ]] && msg YELLOW "Skipped (ownership): ${skipped[*]}"
    [[ ${#not_found[@]} -gt 0 ]] && msg YELLOW "Not found: ${not_found[*]}"

    # Return 1 if files are missing (need Phase 2)
    [[ ${#not_found[@]} -gt 0 ]] && return 1
    return 0
}

change_shell() {
    msg GREEN "Changing shell to zsh..."

    local zsh_path=$(command -v zsh)
    [[ -z "$zsh_path" ]] && { err "zsh not found"; exit 1; }
    [[ ! -x "$zsh_path" ]] && { err "zsh not executable"; exit 1; }
    
    if ! grep -qx "$zsh_path" /etc/shells 2>/dev/null; then
        if [[ "$zsh_path" =~ ^/[a-zA-Z0-9/_-]+/zsh$ && -x "$zsh_path" ]]; then
            echo "$zsh_path" >> /etc/shells
            msg GREEN "Added $zsh_path to /etc/shells"
        else
            err "Invalid zsh path: $zsh_path"
            exit 1
        fi
    fi
    
    local u_shell=$(get_user_info "$REAL_USER" shell)
    [[ "$u_shell" != "$zsh_path" ]] && { chsh -s "$zsh_path" "$REAL_USER"; msg GREEN "Changed shell for $REAL_USER"; } || msg GREEN "Shell already set for $REAL_USER"

    if [[ "$OS" == "macos" ]]; then
        msg GREEN "Skipping root shell change (not needed on macOS)"
    else
        local r_shell=$(get_user_info "root" shell)
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

    readonly REAL_USER="${SUDO_USER:-$(whoami)}"
    readonly REAL_HOME=$(get_user_info "$REAL_USER" home)
    [[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]] && { err "Cannot determine home directory"; exit 1; }

    # PHASE 2: Marker file exists - check if we need to complete setup
    if [[ -f "$REAL_HOME/.phase1-marker" ]]; then
        msg GREEN "Resuming Phase 2: Checking root symlinks..."

        check_sudo
        detect_os

        check_symlinks_status
        local status=$?

        case $status in
            0)
                # All complete - remove marker and finish
                rm -f "$REAL_HOME/.phase1-marker"
                msg GREEN ""
                msg GREEN "=========================================="
                msg GREEN "Setup Already Complete!"
                msg GREEN "=========================================="
                msg GREEN ""
                msg GREEN "All root symlinks are properly configured."
                msg GREEN "(Marker file removed)"
                ;;
            1)
                # Files still missing
                msg YELLOW "Some dotfiles still missing:"
                [[ ! -f "$REAL_HOME/.p10k.zsh" ]] && msg YELLOW " - .p10k.zsh (run: p10k configure)"
                [[ ! -f "$REAL_HOME/.nanorc" ]] && msg YELLOW " - .nanorc (create manually if needed)"
                msg GREEN ""
                msg GREEN "Run these commands, then run this script again."
                ;;
            2)
                # Files exist but symlinks needed
                msg GREEN "Creating missing symlinks..."
                create_root_symlinks
                local symlink_result=$?
                if [[ $symlink_result -eq 0 ]]; then
                    rm -f "$REAL_HOME/.phase1-marker"
                    show_phase2_complete
                else
                    msg YELLOW "Some symlinks could not be created. Check permissions."
                fi
                ;;
        esac
        exit 0
    fi

    # PHASE 1: Normal installation
    msg GREEN "Starting installation for user: $REAL_USER (home: $REAL_HOME)"

    check_sudo
    detect_os
    update_packages
    install_packages
    backup_dotfiles
    download_zshrc
    create_root_symlinks
    local install_status=$?
    change_shell
    verify_installation
    cleanup_packages

    # Determine completion status
    case $install_status in
        0)
            # All complete
            show_complete_message
            ;;
        1)
            # Need Phase 2
            touch "$REAL_HOME/.phase1-marker"
            chown "$REAL_USER:$(id -gn "$REAL_USER" 2>/dev/null)" "$REAL_HOME/.phase1-marker" 2>/dev/null || true
            show_phase1_message
            ;;
    esac
}

main "$@"
