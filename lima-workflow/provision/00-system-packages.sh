#!/bin/bash
set -eux -o pipefail
# Lima provisioning script — mode: system (root, runs on every `limactl start`).
#
# Base OS packages plus the tools that install system-wide via apt or a root
# installer: GitHub CLI, Azure CLI, Azure Developer CLI and the 1Password CLI.
# Per-user tools (aws-cli, tfenv/Terraform, node, Bicep, Claude Code,
# pre-commit, oh-my-zsh) run unprivileged in the mode:user scripts — see
# 10-/20-/30-user-*.sh. Docker itself comes from `base: template:docker` in
# the VM yaml.
#
# Idempotent: apt installs are naturally safe to repeat; the gh/az/azd/op
# installers are guarded with `command -v` checks.

export DEBIAN_FRONTEND=noninteractive

apt-get update

# git, vim: basic tooling.
# curl, unzip, zip, jq, ca-certificates, gnupg, lsb-release: needed by the
# installers below + general plumbing.
# zsh: login shell (oh-my-zsh itself is installed per-user).
# python3/pip/venv/pipx: Python tooling; pipx is how pre-commit gets installed.
# direnv: per-directory env loading. The binary alone does nothing until its
#   shell hook is wired into .zshrc, which 20-user-tools.sh does.
# openssl: for inspecting/verifying certificates by hand.
apt-get install -y --no-install-recommends \
  git \
  vim \
  curl \
  unzip \
  zip \
  jq \
  ca-certificates \
  gnupg \
  lsb-release \
  locales \
  zsh \
  python3 \
  python3-pip \
  python3-venv \
  pipx \
  direnv \
  openssl

locale-gen en_US.UTF-8

# GitHub CLI — official apt repo.
if ! command -v gh >/dev/null 2>&1; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update
  apt-get install -y gh
fi

# Azure CLI (`az`) — official Microsoft install script (adds the
# packages.microsoft.com apt repo, so later upgrades come through apt).
# -f matters: without it curl exits 0 on an HTTP error and pipes the error page
# to bash, so a rate-limit/outage response would look like a successful install.
if ! command -v az >/dev/null 2>&1; then
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
    https://aka.ms/InstallAzureCLIDeb | bash
fi

# Azure Developer CLI (`azd`) — official install script; drops the binary in
# /usr/local/bin. Not in the Microsoft apt repo, so this is the documented
# Linux route. Same -f/retry reasoning as the Azure CLI above.
if ! command -v azd >/dev/null 2>&1; then
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
    https://aka.ms/install-azd.sh | bash
fi

# 1Password CLI (`op`) — official apt repo, same shape as the GitHub CLI block
# above. CLI only; it is not signed in (see README).
#
# NOTE: 1Password's own instructions add a debsig policy under
# /etc/debsig/policies + /usr/share/debsig/keyrings so dpkg verifies the
# package's embedded signature too. That is deliberately omitted: `debsig-verify`
# isn't installed on this image and isn't pulled in by anything here, so dpkg
# never consults the policy and those four extra commands buy nothing. The
# repository is already authenticated by the signed-by keyring below, which is
# exactly the trust model the gh and az installs above rely on. If you ever add
# `debsig-verify` to this list, add the policy back at the same time.
if ! command -v op >/dev/null 2>&1; then
  # Also created by the gh block above, but that one is guarded - don't depend
  # on it having run in this pass.
  install -d -m 0755 /etc/apt/keyrings
  OP_ARCH="$(dpkg --print-architecture)"
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
    https://downloads.1password.com/linux/keys/1password.asc \
    | gpg --dearmor --output /etc/apt/keyrings/1password-archive-keyring.gpg
  chmod go+r /etc/apt/keyrings/1password-archive-keyring.gpg
  echo "deb [arch=$OP_ARCH signed-by=/etc/apt/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$OP_ARCH stable main" \
    > /etc/apt/sources.list.d/1password.list
  apt-get update
  apt-get install -y 1password-cli
fi
