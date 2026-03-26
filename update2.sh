#!/usr/bin/env bash

if [[ -z "${UPDATE2_RELAUNCHED:-}" && -p /dev/stdin ]]; then
  tmp_script=$(mktemp "/tmp/update2.XXXXXX.sh")
  cat > "$tmp_script"
  chmod +x "$tmp_script"
  UPDATE2_RELAUNCHED=1
  env UPDATE2_RELAUNCHED=1 PS1= PROMPT_COMMAND= TERM=dumb script -q /dev/null bash "$tmp_script" "$@"
  rc=$?
  rm -f "$tmp_script"
  exit "$rc"
fi

set -euo pipefail

readonly REPO_URL="https://raw.githubusercontent.com/Oculto54/Utils/main"
readonly DOTFILES=(.nanorc .p10k.zsh .zshrc .zshrc-profile)
OS_TYPE=""
commands=()
cleanup_commands=()
SUDO_PREFIX=""
REAL_USER=""
HOME_DIR=""
NANO_SYNTAX_DIR=""
TMP_DIR=""
BACKUP_DIR=""

info() {
  printf "\033[0;32m[INFO]\033[0m %s\n" "$1"
}

warn() {
  printf "\033[0;33m[WARN]\033[0m %s\n" "$1"
}

error() {
  printf "\033[0;31m[ERROR]\033[0m %s\n" "$1" >&2
}

die() {
  trap - ERR
  error "$1"
  exit 1
}

trap 'die "Script aborted near line ${LINENO:-?}."' ERR

ask_yes_no() {
  local prompt="$1"
  local default_answer="${2:-y}"
  local answer=""
  local display
  local tty_fd

  if [[ "$default_answer" =~ ^[Yy]$ ]]; then
    display="Y/n"
  else
    display="y/N"
  fi

  if [[ -t 0 ]]; then
    read -rp "$prompt [$display] " answer
  elif [[ -c /dev/tty ]]; then
    exec {tty_fd}<>/dev/tty
    printf '%s [%s] ' "$prompt" "$display" >&$tty_fd
    IFS= read -r answer <&$tty_fd
    exec {tty_fd}>&-
  else
    warn "No interactive terminal detected; defaulting answer to $default_answer."
    answer="$default_answer"
  fi

  answer="${answer:-$default_answer}"
  case "$answer" in
    [Yy]*) return 0 ;;
    *) return 1 ;;
  esac
}

get_user_shell() {
  local user="$1"
  if [[ "$OS_TYPE" == "macos" ]]; then
    dscl . -read "/Users/$user" UserShell 2>/dev/null | awk '{print $2}'
  else
    getent passwd "$user" | cut -d: -f7
  fi
}

detect_os() {
  if [[ "${OSTYPE:-}" == darwin* ]]; then
    OS_TYPE="macos"
  elif [[ "${OSTYPE:-}" == linux-gnu* ]] || [[ -f /etc/debian_version ]]; then
    OS_TYPE="linux"
  else
    die "Unsupported OS: ${OSTYPE:-unknown}"
  fi
  info "Detected OS: $OS_TYPE"
}

resolve_user_home() {
  local user="$1"
  local home=""

  if [[ "$OS_TYPE" == "macos" ]]; then
    if command -v dscl >/dev/null 2>&1; then
      home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    fi
  else
    home=$(getent passwd "$user" | cut -d: -f6)
  fi

  if [[ -z "$home" ]]; then
    die "Unable to determine home directory for user: $user"
  fi
  echo "$home"
}

init_environment() {
  REAL_USER="${SUDO_USER:-$(whoami)}"
  HOME_DIR="$(resolve_user_home "$REAL_USER")"
  if [[ "$OS_TYPE" == "linux" && $EUID -ne 0 ]]; then
    SUDO_PREFIX="sudo"
  else
    SUDO_PREFIX=""
  fi
  BACKUP_DIR="$HOME_DIR/.dotfiles_backup_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  info "Running as $REAL_USER" 
  info "Home directory: $HOME_DIR"
}

setup_commands() {
  commands=()
  cleanup_commands=()

  if [[ "$OS_TYPE" == "macos" ]]; then
    commands+=("Ensure Homebrew::step_install_homebrew")
    commands+=("Update and upgrade Homebrew::step_brew_update_upgrade")
    commands+=("Install required packages via Homebrew::step_brew_install_packages")
    cleanup_commands+=("Clean Homebrew cache::step_brew_cleanup")
  else
    commands+=("Update and upgrade apt packages::step_apt_update_upgrade")
    commands+=("Install required packages via apt::step_apt_install_packages")
    cleanup_commands+=("Autoremove and autoclean apt::step_apt_cleanup")
  fi
}

run_commands() {
  for entry in "${commands[@]}"; do
    local description="${entry%%::*}"
    local action="${entry##*::}"
    info "== $description =="
    "$action"
  done
}

run_cleanup_commands() {
  for entry in "${cleanup_commands[@]}"; do
    local description="${entry%%::*}"
    local action="${entry##*::}"
    info "== $description =="
    "$action"
  done
}

run_root_cmd() {
  if [[ -n "$SUDO_PREFIX" ]]; then
    "$SUDO_PREFIX" "$@"
  else
    "$@"
  fi
}

step_install_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    info "Homebrew already available"
    return
  fi
  info "Installing Homebrew (noninteractive)"
  if [[ -n "${SUDO_USER:-}" ]]; then
    su - "$REAL_USER" -c 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  else
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  if [[ -d /opt/homebrew/bin ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -d /usr/local/bin ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

step_brew_update_upgrade() {
  brew update
  brew upgrade
}

step_brew_install_packages() {
  brew install git nano zsh curl wget btop
}

step_brew_cleanup() {
  brew cleanup
}

step_apt_update_upgrade() {
  local prefix=()
  [[ -n "$SUDO_PREFIX" ]] && prefix+=("$SUDO_PREFIX")
  DEBIAN_FRONTEND=noninteractive "${prefix[@]}" apt-get update
  DEBIAN_FRONTEND=noninteractive "${prefix[@]}" apt-get upgrade -y
}

step_apt_install_packages() {
  local prefix=()
  [[ -n "$SUDO_PREFIX" ]] && prefix+=("$SUDO_PREFIX")
  DEBIAN_FRONTEND=noninteractive "${prefix[@]}" apt-get install -y git nano zsh curl wget btop
}

step_apt_cleanup() {
  local prefix=()
  [[ -n "$SUDO_PREFIX" ]] && prefix+=("$SUDO_PREFIX")
  DEBIAN_FRONTEND=noninteractive "${prefix[@]}" apt-get autoremove -y
  DEBIAN_FRONTEND=noninteractive "${prefix[@]}" apt-get autoclean
}

determine_nano_syntax_dir() {
  local candidates=()
  if [[ "$OS_TYPE" == "macos" ]]; then
    if command -v brew >/dev/null 2>&1; then
      local prefix
      prefix=$(brew --prefix 2>/dev/null || true)
      [[ -n "$prefix" ]] && candidates+=("$prefix/share/nano")
    fi
    candidates+=("/opt/homebrew/share/nano" "/usr/local/share/nano" "/usr/share/nano")
  else
    candidates+=("/usr/share/nano")
  fi

  for dir in "${candidates[@]}"; do
    if [[ -d "$dir" ]]; then
      NANO_SYNTAX_DIR="$dir"
      info "Found nano syntax directory: $NANO_SYNTAX_DIR"
      return
    fi
  done

  warn "Nano syntax directory not found; .nanorc include line will be skipped"
}

download_file() {
  local file="$1"
  local dest="$2"
  local url="$REPO_URL/$file"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 30 "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=30 -O "$dest" "$url"
  else
    die "curl or wget is required to download $file"
  fi
  if [[ ! -s "$dest" ]]; then
    die "Downloaded $file is empty"
  fi
}

download_dotfiles() {
  TMP_DIR=$(mktemp -d)
  info "Downloading dotfiles to temporary directory"
  for file in "${DOTFILES[@]}"; do
    download_file "$file" "$TMP_DIR/$file"
  done
}

backup_existing_dotfiles() {
  info "Backing up existing dotfiles (if present) to $BACKUP_DIR"
  for file in "${DOTFILES[@]}"; do
    if [[ -f "$HOME_DIR/$file" ]]; then
      cp -p "$HOME_DIR/$file" "$BACKUP_DIR/$file"
      info "Backed up $file"
    fi
  done
}

install_from_temp() {
  local file="$1"
  cp -f "$TMP_DIR/$file" "$HOME_DIR/$file"
  chmod 644 "$HOME_DIR/$file"
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown "$REAL_USER:$(id -gn "$REAL_USER")" "$HOME_DIR/$file" 2>/dev/null || true
  fi
  info "Installed $file"
}

ensure_nanorc_include_line() {
  local nanorc_path="$HOME_DIR/.nanorc"
  [[ -z "$NANO_SYNTAX_DIR" ]] && return
  [[ ! -f "$nanorc_path" ]] && return

  local include_line="include \"$NANO_SYNTAX_DIR/*.nanorc\""
  local second_line
  second_line=$(sed -n '2p' "$nanorc_path" 2>/dev/null || true)
  if [[ "$second_line" == "$include_line" ]]; then
    info ".nanorc already includes nano syntax line"
    return
  fi

  local first_line
  first_line=$(sed -n '1p' "$nanorc_path" 2>/dev/null || true)
  local remaining
  remaining=$(tail -n +2 "$nanorc_path" 2>/dev/null || true)
  local temp
  temp=$(mktemp)

  {
    if [[ -n "$first_line" ]]; then
      printf '%s\n' "$first_line"
    else
      printf '\n'
    fi
    printf '%s\n' "$include_line"
    printf '%s\n' "$remaining"
  } > "$temp"

  mv "$temp" "$nanorc_path"
  chmod 644 "$nanorc_path"
  [[ -n "${SUDO_USER:-}" ]] && chown "$REAL_USER:$(id -gn "$REAL_USER")" "$nanorc_path" 2>/dev/null || true
  info "Ensured nano include line in .nanorc"
}

handle_dotfiles() {
  download_dotfiles
  backup_existing_dotfiles

  local tmp_file
  tmp_file="$TMP_DIR/.zshrc-profile"
  if [[ ! -f "$tmp_file" ]]; then
    die ".zshrc-profile download is required"
  fi
  install_from_temp ".zshrc-profile"

  if [[ -f "$HOME_DIR/.nanorc" ]]; then
    if ask_yes_no "Replace existing .nanorc?" "n"; then
      install_from_temp ".nanorc"
    else
      info "Keeping existing .nanorc"
    fi
  else
    install_from_temp ".nanorc"
  fi

  ensure_nanorc_include_line

  if [[ -f "$HOME_DIR/.zshrc" ]]; then
    if ask_yes_no "Replace existing .zshrc?" "n"; then
      install_from_temp ".zshrc"
    else
      info "Keeping existing .zshrc"
    fi
  else
    install_from_temp ".zshrc"
  fi

  if [[ -f "$HOME_DIR/.p10k.zsh" ]]; then
    if ask_yes_no "Replace existing .p10k.zsh?" "n"; then
      install_from_temp ".p10k.zsh"
    else
      info "Keeping existing .p10k.zsh"
    fi
  else
    install_from_temp ".p10k.zsh"
  fi
}

create_root_symlinks() {
  if [[ "$OS_TYPE" != "linux" ]]; then
    return
  fi
  [[ ! -d /root ]] && return
  if ! ask_yes_no "Create /root symlinks for the dotfiles?" "y"; then
    info "Skipping root symlinks"
    return
  fi
  for file in "${DOTFILES[@]}"; do
    local target="$HOME_DIR/$file"
    [[ ! -f "$target" ]] && continue
    run_root_cmd ln -sf "$target" "/root/$file"
    info "Created /root/$file -> $target"
  done
}

ensure_zsh_shell_setting() {
  local zsh_path
  zsh_path=$(command -v zsh || true)
  [[ -z "$zsh_path" ]] && die "zsh not found"

  local current_shell
  current_shell=$(get_user_shell "$REAL_USER" || true)

  if [[ "$current_shell" == "$zsh_path" ]]; then
    info "$REAL_USER already uses zsh"
  else
    if ask_yes_no "Change default shell for $REAL_USER to zsh?" "y"; then
      if ! grep -Fxq "$zsh_path" /etc/shells 2>/dev/null; then
        if [[ -n "$SUDO_PREFIX" ]]; then
          run_root_cmd sh -c "printf '%s\n' '$zsh_path' >> /etc/shells"
        else
          printf '%s\n' "$zsh_path" >> /etc/shells
        fi
      fi
      chsh -s "$zsh_path" "$REAL_USER"
      info "Default shell changed to zsh for $REAL_USER"
    else
      info "Keeping existing shell for $REAL_USER"
    fi
  fi

  if [[ "$OS_TYPE" == "linux" ]]; then
    local root_shell
    root_shell=$(get_user_shell root || true)
    if [[ "$root_shell" != "$zsh_path" ]]; then
      if ask_yes_no "Change root shell to zsh?" "y"; then
        if [[ -n "$SUDO_PREFIX" ]]; then
          run_root_cmd chsh -s "$zsh_path" root
        else
          chsh -s "$zsh_path" root
        fi
        info "Root shell changed to zsh"
      else
        info "Root shell kept as $root_shell"
      fi
    else
      info "Root already uses zsh"
    fi
  fi
}

cleanup_temp_dir() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}

main() {
  detect_os
  init_environment
  setup_commands
  run_commands
  determine_nano_syntax_dir
  handle_dotfiles
  create_root_symlinks
  ensure_zsh_shell_setting
  run_cleanup_commands
  cleanup_temp_dir
  info "Dotfiles updated; reloading shell"
  cd "$HOME_DIR"
  exec zsh -l
}

main "$@"
