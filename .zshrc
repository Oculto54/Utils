#!/usr/bin/env zsh
# zmodload zsh/zprof
# =============================================================================
# Minimal Cross-Platform Zsh Configuration
# =============================================================================

# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# =============================================================================
# Cached Platform Detection (faster)
# =============================================================================
# Platform Detection
export PLATFORM="unknown"
export PLATFORM_DISTRO="unknown"
export PACKAGE_MANAGER="unknown"

if [[ -z "$PLATFORM_CACHE" ]]; then
  if [[ "$OSTYPE" == "darwin"* ]]; then
    export PLATFORM="macos"
    export PLATFORM_DISTRO="macos"
    [[ "$(uname -m)" == "arm64" ]] && export HOMEBREW_PREFIX="/opt/homebrew" || export HOMEBREW_PREFIX="/usr/local"
    [[ -x "${HOMEBREW_PREFIX}/bin/brew" ]] && { export PACKAGE_MANAGER="brew"; eval "$(${HOMEBREW_PREFIX}/bin/brew shellenv)" 2>/dev/null; }
  elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    export PLATFORM="linux"
    [[ -f /etc/os-release ]] && { source /etc/os-release 2>/dev/null; export PLATFORM_DISTRO="$ID"; }
    case "$PLATFORM_DISTRO" in
      "debian"|"ubuntu"|"raspbian") export PACKAGE_MANAGER="apt" ;;
      "arch"|"manjaro") export PACKAGE_MANAGER="pacman" ;;
      "fedora"|"centos"|"rhel") export PACKAGE_MANAGER="dnf" ;;
      "alpine") export PACKAGE_MANAGER="apk" ;;
      *) export PACKAGE_MANAGER="apt" ;;
    esac
  fi
  export PLATFORM_CACHE=1
fi



# =============================================================================
# History
# =============================================================================
HISTSIZE=10000
HISTFILE=~/.zsh_history
SAVEHIST=$HISTSIZE

setopt appendhistory sharehistory hist_ignore_space hist_ignore_all_dups hist_find_no_dups

# =============================================================================
# Shell Settings
# =============================================================================
export EDITOR=nano

# LS Colors
if command -v dircolors &>/dev/null; then
  eval "$(dircolors -b)" 2>/dev/null
fi

export LS_COLORS="di=1;34:ln=1;36:so=1;35:pi=33:ex=1;32:bd=33;47:cd=33;47:su=37;41:sg=30;43:"

# =============================================================================
# Aliases
# =============================================================================
if [[ "$PLATFORM" == "macos" ]]; then
  export CLICOLOR=1
  alias ls='ls -G'
  alias ll='ls -lah'
  alias update='brew update && brew upgrade'
else
  alias ls='ls --color=auto'
  alias ll='ls --color=auto -lah'
  [[ "$PACKAGE_MANAGER" == "apt" ]] && alias update='sudo apt update && sudo apt upgrade -y'
  [[ "$PACKAGE_MANAGER" == "pacman" ]] && alias update='sudo pacman -Syu'
  [[ "$PACKAGE_MANAGER" == "dnf" ]] && alias update='sudo dnf update -y'
fi

alias ..='cd ..'
alias ...='cd ../..'
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
alias h='history'
alias c='clear'


# =============================================================================
# Path
# =============================================================================
typeset -U path PATH  # Remove duplicates
path=("$HOME/.local/bin" "$HOME/.cargo/bin" "$path[@]")
[[ "$PLATFORM" == "macos" ]] && path=("${HOMEBREW_PREFIX}/bin" "${HOMEBREW_PREFIX}/sbin" "$path[@]")
[[ -d "$HOME/.lmstudio/bin" ]] && path+=("$HOME/.lmstudio/bin")

# =============================================================================
# Nano Config (only if missing)
# =============================================================================
[[ ! -f "$HOME/.nanorc" ]] && printf 'set linenumbers\nset autoindent\nset mouse\nset tabsize 2\n' > "$HOME/.nanorc" 2>/dev/null

# =============================================================================
# iTerm2 (macOS only)
# =============================================================================
[[ "$PLATFORM" == "macos" && -f "$HOME/.iterm2_shell_integration.zsh" ]] && source "$HOME/.iterm2_shell_integration.zsh"


# =============================================================================
# Nano Config (marker at top - prevents duplication)
# =============================================================================
NANORC_MARKER="# CONFIGURED_BY_ZSHRC"
NANORC_CHECK="${XDG_CACHE_HOME:-$HOME/.cache}/.nanorc_weekly"

setup_nanorc() {
    local nanorc="$HOME/.nanorc"
    
    # Check if file exists AND has marker at first line
    if [[ -f "$nanorc" ]] && [[ "$(head -1 "$nanorc" 2>/dev/null)" == "$NANORC_MARKER" ]]; then
        return 0
    fi
    
    # Create fresh file (overwrites any duplicates)
    {
        echo "$NANORC_MARKER"
        echo "set linenumbers"
        echo "set autoindent"
        echo "set mouse"
        echo "set tabsize 2"
        
        for dir in /usr/share/nano /usr/local/share/nano /opt/homebrew/share/nano /opt/local/share/nano; do
            [[ -d "$dir" ]] && echo "include \"$dir/*.nanorc\""
        done
    } > "$nanorc" 2>/dev/null
}

# Weekly check
if [[ -z "$NANORC_WEEKLY_DONE" ]] && [[ -n "$NANORC_CHECK"(#qN.mh+168) ]]; then
    export NANORC_WEEKLY_DONE=1
    ( setup_nanorc && touch "$NANORC_CHECK" 2>/dev/null ) &>/dev/null &|
fi



# =============================================================================
# Zinit (lazy loaded)
# =============================================================================
ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"

# Clone zinit only if missing (skip check on subsequent loads)
if [[ ! -d "$ZINIT_HOME/.git" ]]; then
  mkdir -p "$(dirname $ZINIT_HOME)"
  git clone --depth 1 https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME" 2>/dev/null
fi

# Load zinit
[[ -f "${ZINIT_HOME}/zinit.zsh" ]] && source "${ZINIT_HOME}/zinit.zsh"

# Load plugins (conditional)
if (( $+functions[zinit] )); then
  zinit light zsh-users/zsh-completions
  zinit light zsh-users/zsh-autosuggestions
  zinit light zsh-users/zsh-syntax-highlighting
  zinit ice depth=1; zinit light romkatv/powerlevel10k
fi

# Completions (cached for 24h)
autoload -Uz compinit
if [[ -n ~/.zcompdump(#qN.mh+24) ]]; then
  compinit -i
else
  compinit -i -C  # Use cached
fi
zinit cdreplay -q

# Powerlevel10k
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

# Completion styling
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"


# =============================================================================
# Weekly Auto-Update (detached background - won't block exit)
# =============================================================================
ZSHRC_UPDATE_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/.zshrc_last_update"

# Check and run updates in detached background
(
  if [[ ! -f "$ZSHRC_UPDATE_FILE" ]] || [[ -n "$ZSHRC_UPDATE_FILE"(#qN.mh+168) ]]; then
    (( $+functions[zinit] )) && {
      zinit self-update &>/dev/null
      zinit update --all --parallel &>/dev/null
    }
    [[ "$PLATFORM" == "macos" ]] && command -v brew &>/dev/null && {
      brew update &>/dev/null
      brew upgrade &>/dev/null
    }
    [[ "$PLATFORM" == "linux" && "$PACKAGE_MANAGER" == "apt" ]] && sudo apt update &>/dev/null
    touch "$ZSHRC_UPDATE_FILE"
  fi
) &>/dev/null &!


# zprof
