#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/Oculto54/Utils/main"
DOTFILES=(.nanorc .p10k.zsh .zshrc .zshrc-profile .update-repo.sh)
BREW_PKGS=(git nano zsh curl wget btop)
APT_PKGS=(git nano zsh curl wget btop)

info() { printf "\033[0;32m[INFO]\033[0m %s\n" "$1"; }
warn() { printf "\033[0;33m[WARN]\033[0m %s\n" "$1"; }
error() { printf "\033[0;31m[ERROR]\033[0m %s\n" "$1" >&2; }

die() { error "$1"; exit 1; }

maybe_rerun_in_pseudo_tty() {
  if [[ -n "${UPDATE_INTERACTIVE:-}" ]]; then
    return
  fi
  if [[ -t 0 && -t 1 ]]; then
    return
  fi

  local source_path="${BASH_SOURCE[0]:-$0}"
  local interactive_script="$source_path"
  local cleanup_script=false
  if [[ ! -f "$interactive_script" ]]; then
    interactive_script=$(mktemp "/tmp/update2.XXXXXX.sh")
    cleanup_script=true
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$REPO_URL/update.sh" -o "$interactive_script"
    elif command -v wget >/dev/null 2>&1; then
      wget -q --timeout=30 -O "$interactive_script" "$REPO_URL/update.sh"
    else
      warn "curl or wget is required to relaunch interactively"
      [[ "$cleanup_script" == true ]] && rm -f "$interactive_script"
      return
    fi
  fi

  chmod +x "$interactive_script"

  local helper=""
  if command -v python3 >/dev/null 2>&1; then
    helper="python3"
  elif command -v python >/dev/null 2>&1; then
    helper="python"
  elif command -v script >/dev/null 2>&1; then
    helper="script"
  else
    warn "No pseudo-tty helper available; prompts will default"
    [[ "$cleanup_script" == true ]] && rm -f "$interactive_script"
    return
  fi

  info "Re-running update.sh inside a pseudo-tty for prompts"
  local rc=0
  if [[ "$helper" == "script" ]]; then
    UPDATE_INTERACTIVE=1 script -q /dev/null bash "$interactive_script" "$@"
    rc=$?
  else
    UPDATE_INTERACTIVE=1 "$helper" - "$interactive_script" "$@" <<'PY'
import os, sys, pty
script = sys.argv[1]
args = ["bash", script] + sys.argv[2:]
status = pty.spawn(args)
os._exit(status >> 8)
PY
    rc=$?
  fi

  [[ "$cleanup_script" == true ]] && rm -f "$interactive_script"
  exit "$rc"
}
maybe_rerun_in_pseudo_tty "$@"

OS_TYPE=""
SUDO_PREFIX=""
REAL_USER=""
HOME_DIR=""
BACKUP_DIR=""
TMP_DIR=""
NANO_SYNTAX_DIR=""

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local answer=""
  local display
  if [[ "$default" =~ ^[Yy]$ ]]; then
    display="Y/n"
  else
    display="y/N"
  fi

  if [[ -t 0 ]]; then
    read -rp "$prompt [$display] " answer
  else
    warn "Non-interactive shell; defaulting to $default"
    answer="$default"
  fi

  answer="${answer:-$default}"
  case "$answer" in
    [Yy]*) return 0 ;; 
    *) return 1 ;; 
  esac
}

detect_os() {
  case "${OSTYPE:-}" in
    darwin*) OS_TYPE="macos" ;; 
    linux-gnu* | *BSD*) [[ -f /etc/debian_version ]] && OS_TYPE="linux" && return ;; 
    *) die "Unsupported OS: ${OSTYPE:-unknown}" ;; 
  esac
  info "Detected OS: $OS_TYPE"
}

resolve_user_home() {
  local user="$1"
  if [[ "$OS_TYPE" == "macos" ]]; then
    dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
  else
    getent passwd "$user" | cut -d: -f6
  fi
}

get_user_shell() {
  local user="$1"
  if [[ "$OS_TYPE" == "macos" ]]; then
    dscl . -read "/Users/$user" UserShell 2>/dev/null | awk '{print $2}'
  else
    getent passwd "$user" | cut -d: -f7
  fi
}

init_env() {
  REAL_USER="${SUDO_USER:-$(whoami)}"
  HOME_DIR="$(resolve_user_home "$REAL_USER")"
  [[ -z "$HOME_DIR" ]] && die "Home directory for $REAL_USER not found"
  BACKUP_DIR="$HOME_DIR/.dotfiles_backup_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  [[ "$OS_TYPE" == "linux" && $EUID -ne 0 ]] && SUDO_PREFIX="sudo" || SUDO_PREFIX=""
  info "Running as $REAL_USER (home: $HOME_DIR)"
}

run_command() {
  info "== $1 =="
  shift
  "$@"
}

ensure_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    info "Installing Homebrew"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -d /opt/homebrew/bin ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -d /usr/local/bin ]]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
  else
    info "Homebrew already installed"
  fi
}

brew_update() { brew update && brew upgrade; }
brew_install() { brew install "${BREW_PKGS[@]}"; }
brew_cleanup() { brew cleanup; }

apt_exec() {
  local args=(apt-get "$@")
  if [[ -n "$SUDO_PREFIX" ]]; then
    "$SUDO_PREFIX" env DEBIAN_FRONTEND=noninteractive "${args[@]}"
  else
    env DEBIAN_FRONTEND=noninteractive "${args[@]}"
  fi
}

apt_update_upgrade() {
  apt_exec update
  apt_exec upgrade -y
}

apt_install() {
  apt_exec install -y "${APT_PKGS[@]}"
}

apt_cleanup() {
  apt_exec autoremove -y
  apt_exec autoclean
}

download_dotfiles() {
  TMP_DIR="${TMPDIR:-$(mktemp -d)}"
  info "Downloading dotfiles"
  for file in "${DOTFILES[@]}"; do
    local dest="$TMP_DIR/$file"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --max-time 30 "$REPO_URL/$file" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
      wget -q --timeout=30 -O "$dest" "$REPO_URL/$file"
    else
      die "curl or wget is required"
    fi
    [[ -s "$dest" ]] || die "Downloaded $file is empty"
  done
}

backup_dotfiles() {
  info "Backing up existing dotfiles to $BACKUP_DIR"
  for file in "${DOTFILES[@]}"; do
    [[ -f "$HOME_DIR/$file" ]] && cp -p "$HOME_DIR/$file" "$BACKUP_DIR/$file" && info "Backed up $file"
  done
}

install_file() {
  local file="$1"
  cp -f "$TMP_DIR/$file" "$HOME_DIR/$file"
  if [[ "$file" == ".update-repo.sh" ]]; then
    chmod 755 "$HOME_DIR/$file"
  else
    chmod 644 "$HOME_DIR/$file"
  fi
  [[ -n "${SUDO_USER:-}" ]] && chown "$REAL_USER:$(id -gn "$REAL_USER")" "$HOME_DIR/$file" 2>/dev/null || true
  info "Installed $file"
}

ensure_nanorc_include() {
  [[ -z "$NANO_SYNTAX_DIR" ]] && return
  local target="$HOME_DIR/.nanorc"
  [[ ! -f "$target" ]] && return
  local include_line="include \"$NANO_SYNTAX_DIR/*.nanorc\""
  local second_line
  second_line=$(sed -n '2p' "$target" 2>/dev/null || true)
  [[ "$second_line" == "$include_line" ]] && return
  { head -n1 "$target" 2>/dev/null; printf '%s\n' "$include_line"; tail -n +2 "$target" 2>/dev/null; } > "$target.new"
  mv "$target.new" "$target"
  chmod 644 "$target"
  [[ -n "${SUDO_USER:-}" ]] && chown "$REAL_USER:$(id -gn "$REAL_USER")" "$target" 2>/dev/null || true
  info "Ensured nano include"
}

dotfile_mode_setup() {
  case "$1" in
    .zshrc-profile|.update-repo.sh) install_file "$1" ;; 
    *)
      if [[ -f "$HOME_DIR/$1" ]]; then
        if ask_yes_no "Replace existing $1?" "n"; then
          install_file "$1"
        else
          info "Keeping $1"
        fi
      else
        install_file "$1"
      fi
      ;; 
  esac
}

determine_nano_dir() {
  local dirs=("/usr/share/nano")
  if [[ "$OS_TYPE" == "macos" ]]; then
    local prefix
    prefix=$(brew --prefix 2>/dev/null || true)
    [[ -n "$prefix" ]] && dirs=($prefix/share/nano "/opt/homebrew/share/nano" "/usr/local/share/nano" "/usr/share/nano")
  fi
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] && { NANO_SYNTAX_DIR="$d"; info "Nano syntax: $d"; return; }
  done
  warn "Nano syntax directory not found"
}

create_root_links() {
  [[ "$OS_TYPE" != "linux" || ! -d /root ]] && return
  if ask_yes_no "Create /root symlinks for dotfiles?" "y"; then
    for file in "${DOTFILES[@]}"; do
      [[ ! -f "$HOME_DIR/$file" ]] && continue
      run_root_cmd ln -sf "$HOME_DIR/$file" "/root/$file"
      info "Linked /root/$file"
    done
  else
    info "Skipped /root symlinks"
  fi
}

run_root_cmd() {
  if [[ -n "$SUDO_PREFIX" ]]; then
    "$SUDO_PREFIX" "$@"
  else
    "$@"
  fi
}

change_shell() {
  local zsh_path
  zsh_path=$(command -v zsh || true)
  [[ -z "$zsh_path" ]] && die "zsh not installed"
  local target_shell
  target_shell=$(get_user_shell "$REAL_USER" 2>/dev/null || true)
  target_shell="${target_shell:-${SHELL:-}}"
  local target_shell_name
  target_shell_name="${target_shell##*/}"
  if [[ "$target_shell" == "$zsh_path" || "$target_shell_name" == "zsh" ]]; then
    info "$REAL_USER already uses zsh"
  else
    if ask_yes_no "Change $REAL_USER shell to zsh?" "y"; then
      grep -qx "$zsh_path" /etc/shells || run_root_cmd bash -c "printf '%s\n' '$zsh_path' >> /etc/shells"
      chsh -s "$zsh_path" "$REAL_USER"
      info "Shell for $REAL_USER set to zsh"
    fi
  fi
  if [[ "$OS_TYPE" == "linux" ]]; then
    local root_shell
    root_shell=$(get_user_shell root || true)
    root_shell="${root_shell:-$zsh_path}"
    if [[ "$root_shell" != "$zsh_path" ]] && ask_yes_no "Change root shell to zsh?" "y"; then
      run_root_cmd chsh -s "$zsh_path" root
      info "Root shell set to zsh"
    fi
  fi
}

cleanup_packages() {
  [[ "$OS_TYPE" == "macos" ]] && brew_cleanup || apt_cleanup
}

finalize() {
  [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
  info "Dotfiles installed; starting zsh"
  cd "$HOME_DIR"
  exec zsh -l
}

main() {
  detect_os
  init_env
  if [[ "$OS_TYPE" == "macos" ]]; then
    run_command "Ensure Homebrew" ensure_brew
    run_command "Update Homebrew" brew_update
    run_command "Install packages" brew_install
  else
    run_command "Update apt" apt_update_upgrade
    run_command "Install packages" apt_install
  fi
  determine_nano_dir
  download_dotfiles
  backup_dotfiles
  for file in "${DOTFILES[@]}"; do
    dotfile_mode_setup "$file"
  done
  ensure_nanorc_include
  create_root_links
  change_shell
  cleanup_packages
  finalize
}

main "$@"
