#!/bin/bash
set -eux -o pipefail
# Lima provisioning script — mode: user (runs as the guest user, on every boot).
#
# Git setup + secrets bootstrap (GitHub SSH key, git identity, optional
# Terraform Cloud token).
#
# lima-workflow/initialize_secrets.sh is gitignored (real credentials) and
# populated per-VM from initialize_secrets.sh.example — it may not exist yet
# on a fresh clone, so this is a soft "run it if present" rather than a hard
# requirement.
#
# Azure login is deliberately NOT automated here: `az login --use-device-code`
# is interactive and its tokens persist in ~/.azure across restarts (see
# README "Logging in to Azure").
#
# Idempotent: `git config --global` and the known_hosts step are safe to
# repeat; initialize_secrets.sh itself is safe to re-run (it only overwrites
# its own credential files under $HOME).
#
# Locate initialize_secrets.sh relative to this script's own directory rather
# than hardcoding the guest mount path — the mount point lives in exactly one
# place (param.project in ubuntu24-docker.yaml), and scripts
# under provision/ shouldn't need a second copy of it to find their siblings.
LIMA_WORKFLOW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Make git reach github.com over SSH even when a repo's origin is an https URL.
#
# The workspace repos are cloned on the Mac, so their .git (and therefore their
# remote URLs) lives on the shared mount — and Mac clones are usually https,
# authenticated by the osxkeychain credential helper. The guest has no
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

SECRETS_SCRIPT="$LIMA_WORKFLOW_DIR/initialize_secrets.sh"
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
  echo "No $SECRETS_SCRIPT yet - copy initialize_secrets.sh.example and fill in your own credentials to enable this step." >&2
fi
