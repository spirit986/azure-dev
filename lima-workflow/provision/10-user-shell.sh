#!/bin/bash
set -eux -o pipefail
# Lima provisioning script — mode: user (runs as the guest user, on every boot).
#
# oh-my-zsh + plugins/theme (plugins git, docker, ssh-agent, npm,
# zsh-autosuggestions).
#
# The theme is "edvardm". It ships with oh-my-zsh
# (themes/edvardm.zsh-theme), so the clone below is all it needs; a theme
# that did NOT ship upstream would additionally have to be cloned into
# $ZSH_CUSTOM/themes/ the way zsh-autosuggestions is below.
#
# Idempotent: install steps are guarded by existence checks on the *files* they
# produce; the .zshrc edits are rewrite-or-insert so re-running doesn't
# duplicate lines.
#
# NOTE: Lima seeds every new guest account with a minimal .zshrc of its own
# (a "# Lima BEGIN/END" block that puts /usr/sbin,/sbin on PATH). Since it
# carries no ZSH_THEME/plugins/source lines, oh-my-zsh's own .zshrc template
# has to replace it (keeping a .zshrc.pre-oh-my-zsh backup, as upstream's
# installer does) and Lima's PATH block then gets restored into the new file.
#
# NOTE: oh-my-zsh is installed by cloning the repo directly rather than by
# piping tools/install.sh from raw.githubusercontent.com. That installer's job
# is only to clone the repo and drop its .zshrc template, but it is served by
# raw.githubusercontent.com, which fails independently of github.com: during a
# GitHub incident on 2026-08-17 it returned HTTP 429 for hours while
# `git clone` kept working fine. Cloning keeps provisioning on the single
# endpoint this VM already depends on. Same reasoning for nvm in 20-user-tools.sh.

OMZ_DIR="$HOME/.oh-my-zsh"

LIMA_ZSHRC_SNIPPET=""
if [ -f "$HOME/.zshrc" ] && grep -q '# Lima BEGIN' "$HOME/.zshrc"; then
  LIMA_ZSHRC_SNIPPET="$(sed -n '/# Lima BEGIN/,/# Lima END/p' "$HOME/.zshrc")"
fi

# Guard on oh-my-zsh.sh (the file .zshrc sources), NOT on $OMZ_DIR: a failed
# install can leave the directory behind while the install itself never
# happened — the zsh-autosuggestions clone below creates
# $OMZ_DIR/custom/plugins/... as a side effect — and a directory-existence
# guard then skips the real install on every subsequent boot, so the VM never
# self-heals on restart.
if [ ! -f "$OMZ_DIR/oh-my-zsh.sh" ]; then
  # Move any partial tree aside so `git clone` has a clean target (and so
  # upstream's "the $ZSH folder already exists" refusal can't apply either).
  if [ -d "$OMZ_DIR" ]; then
    rm -rf "$OMZ_DIR.partial"
    mv "$OMZ_DIR" "$OMZ_DIR.partial"
  fi

  git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$OMZ_DIR"

  # Carry over anything a previous partial run had already put under custom/
  # (themes/plugins), then drop the leftovers.
  if [ -d "$OMZ_DIR.partial" ]; then
    if [ -d "$OMZ_DIR.partial/custom" ]; then
      cp -a "$OMZ_DIR.partial/custom/." "$OMZ_DIR/custom/"
    fi
    rm -rf "$OMZ_DIR.partial"
  fi

  # What tools/install.sh does with the template: back up whatever .zshrc was
  # there, then lay down the real one (ZSH/ZSH_THEME/plugins + the source line).
  if [ -f "$HOME/.zshrc" ]; then
    cp "$HOME/.zshrc" "$HOME/.zshrc.pre-oh-my-zsh"
  fi
  cp "$OMZ_DIR/templates/zshrc.zsh-template" "$HOME/.zshrc"
fi

if [ -n "$LIMA_ZSHRC_SNIPPET" ] && ! grep -q '# Lima BEGIN' "$HOME/.zshrc"; then
  printf '%s\n' "$LIMA_ZSHRC_SNIPPET" >> "$HOME/.zshrc"
fi

ZSH_CUSTOM="${ZSH_CUSTOM:-$OMZ_DIR/custom}"

if [ ! -f "$ZSH_CUSTOM/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ]; then
  rm -rf "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
  git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
    "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
fi

# Set a .zshrc assignment idempotently. A bare
# `sed -i 's/^ZSH_THEME=.*/.../'` silently does nothing when the line isn't
# there at all (exactly the case with Lima's own minimal .zshrc), which is how
# a failed oh-my-zsh install used to surface much later as a confusing
# "theme not wired up" verify failure instead of as a provisioning error.
# So: rewrite in place if declared, otherwise insert it — before oh-my-zsh is
# sourced, since that is when the value is read; appending to the end of the
# file would be a no-op.
zshrc_set() {
  local pattern="$1" line="$2"
  if grep -q "$pattern" "$HOME/.zshrc"; then
    sed -i "s|$pattern.*|$line|" "$HOME/.zshrc"
  elif grep -q '^source .*oh-my-zsh\.sh' "$HOME/.zshrc"; then
    sed -i "/^source .*oh-my-zsh\.sh/i $line" "$HOME/.zshrc"
  else
    printf '%s\n' "$line" >> "$HOME/.zshrc"
  fi
}

zshrc_set '^ZSH_THEME=' 'ZSH_THEME="edvardm"'
zshrc_set '^plugins=(' 'plugins=(git docker ssh-agent npm zsh-autosuggestions)'

# Make zsh the login shell (safe to re-run).
CURRENT_SHELL="$(getent passwd "$(whoami)" | cut -d: -f7)"
if [ "$CURRENT_SHELL" != "$(command -v zsh)" ]; then
  sudo chsh -s "$(command -v zsh)" "$(whoami)"
fi
