#!/bin/bash
set -eux -o pipefail
# Lima provisioning script — mode: user (runs as the guest user, on every boot).
#
# Git setup + secrets bootstrap (GitHub SSH key, git identity, optional
# Terraform Cloud token).
#
# initialize_secrets.sh holds real credentials, so it lives with the project,
# not in this repo: ~/Projects/<project>/.limavm/ on the Mac, which is
# /workspaces/.limavm/ in the guest. It's created per project (per client)
# from initialize_secrets.sh.example and may not exist yet, so this is a soft
# "run it if present" rather than a hard requirement.
#
# Azure login is deliberately NOT automated here: `az login --use-device-code`
# is interactive and its tokens persist in ~/.azure across restarts (see
# README "Logging in to Azure").
#
# Idempotent: `git config --global` and the known_hosts step are safe to
# repeat; initialize_secrets.sh itself is safe to re-run (it only overwrites
# its own credential files under $HOME).

# Fixed guest path: the project folder is always mounted at /workspaces (see
# `mounts:` in ubuntu24-docker.yaml.example).
SECRETS_SCRIPT="/workspaces/.limavm/initialize_secrets.sh"

# Make git reach github.com over SSH even when a repo's origin is an https URL.
#
# Repos cloned on the Mac keep their .git (and therefore their remote URLs) on
# the shared mount — and Mac clones are usually https, authenticated by the
# osxkeychain credential helper. The guest has no
# credential helper, so an https remote just prompts "Username for
# 'https://github.com':" forever, even with a perfectly good SSH key installed.
#
# This rewrite reuses the key initialize_secrets.sh installs, applies to every
# repo in the workspace at once, and lands in the guest's own ~/.gitconfig —
# NOT in the shared .git/config, so the Mac's own remotes stay untouched and
# keep using https. `git config --global` is idempotent.
#
# Not part of initialize_secrets.sh because it's not a secret and is identical
# for every VM: one without that file set up yet still needs this to clone
# over SSH once a key is added.
git config --global url."git@github.com:".insteadOf "https://github.com/"

if [ -f "$SECRETS_SCRIPT" ]; then
  bash "$SECRETS_SCRIPT"

  # initialize_secrets.sh wires up a github.com SSH key but doesn't trust
  # GitHub's host key, so the very first connection fails with
  # "Host key verification failed" instead of prompting (there's no TTY
  # during provisioning to answer the prompt anyway). Pre-seed it once.
  mkdir -p "$HOME/.ssh"
  touch "$HOME/.ssh/known_hosts"
  if ! ssh-keygen -F github.com -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
    ssh-keyscan -t ed25519,rsa github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
  fi
  chmod 644 "$HOME/.ssh/known_hosts"
else
  echo "No $SECRETS_SCRIPT yet - copy initialize_secrets.sh.example to ~/Projects/<project>/.limavm/ on the Mac and fill in your own credentials to enable this step." >&2
fi
