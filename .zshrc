#!/usr/bin/env zsh
# zmodload zsh/zprof
# =============================================================================
# Minimal Cross-Platform Zsh Configuration
# =============================================================================

# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# =============================================================================
# Zsh Options
# =============================================================================
# setopt autocd              # Change dir without typing cd
# setopt extendedglob        # Use extended globbing
setopt noclobber           # Prevent overwriting files with >
setopt correct             # Suggest corrections for typos
setopt nobeep              # Disable beep
# setopt autopushd           # Push old dir to stack on cd
# setopt pushdignoredups     # Don't push duplicate dirs to stack

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

# PATH setup - Remove duplicates
typeset -U path PATH

# User bins (only add if directory exists)
[[ -d "$HOME/.local/bin" ]] && path=("$HOME/.local/bin" "${path[@]}")
[[ -d "$HOME/.cargo/bin" ]] && path=("$HOME/.cargo/bin" "${path[@]}")

# Homebrew (macOS) - works on both Intel and Apple Silicon
if [[ "$OSTYPE" == "darwin"* ]] && command -v brew &>/dev/null; then
  BREW_PREFIX=$(brew --prefix 2>/dev/null)
  [[ -d "$BREW_PREFIX/bin" ]] && path=("$BREW_PREFIX/bin" "$BREW_PREFIX/sbin" "${path[@]}")
fi

# LS Colors
export LS_COLORS="di=1;34:ln=1;36:so=1;35:pi=33:ex=1;32:bd=33;47:cd=33;47:su=37;41:sg=30;43:"

# =============================================================================
# Environment
# =============================================================================
export PAGER="less"
# export LESS="-R -i -g -c -W"
export LESS="-R -i -g -W"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

# =============================================================================
# Aliases
# =============================================================================


alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
alias h='history'
alias c='clear'
alias grep='grep --color=auto'
alias diff='diff --color=auto 2>/dev/null || diff'

# List aliases with colors
if [[ "$OSTYPE" == "darwin"* ]]; then
  alias ls='ls -G'
  alias ll='ls -lahG'
  #alias l='ls -lhG'
  #alias la='ls -laG'
  alias update='brew update && brew upgrade && zinit update --all && zinit self-update --all && brew cleanup'
else
  alias ls='ls --color=auto'
  alias ll='ls --color=auto -lah'
  #alias l='ls --color=auto -lh'
  #alias la='ls --color=auto -la'
  # Only create update alias if apt exists
  command -v apt &>/dev/null && alias update='sudo apt update && sudo apt upgrade -y && zinit update --all && zinit self-update --all && sudo apt autoremove && sudo apt autoclean'
fi

# Directory navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
#alias -- -='cd -'

# =============================================================================
# iTerm2 integration (source if present)
# =============================================================================
[[ -f "$HOME/.iterm2_shell_integration.zsh" ]] && source "$HOME/.iterm2_shell_integration.zsh"

# =============================================================================
# Zinit (lazy loaded)
# =============================================================================
ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"

# Clone zinit only if missing (skip check on subsequent loads)
if [[ ! -d "$ZINIT_HOME/.git" ]]; then
  mkdir -p "$(dirname "$ZINIT_HOME")"
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

# =============================================================================
# Completions
# =============================================================================
autoload -Uz compinit
# Cache compinit for better performance
if [[ -f ~/.zcompdump ]]; then
  compinit -i -C
else
  compinit -i
fi
zinit cdreplay -q

# Powerlevel10k
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

# Completion styling
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"

# zprof