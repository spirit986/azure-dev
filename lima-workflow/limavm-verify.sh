#!/bin/bash
set -u
# Post-provisioning smoke test for a Lima VM built from a project's
# .limavm/ubuntu24-docker.yaml. Run this after `limactl start <VMNAME>` to
# confirm provisioning actually completed instead of eyeballing it.
#
# Usage: limavm-verify.sh <VMNAME>   (from any directory)
#
# Runs EVERY check (it does not stop at the first failure) and reports each
# one as it goes:
#
#   ubuntu 24.04 guest           ... OK
#   zsh theme (edvardm)          ... FAIL
#   ...
#
# then a verdict:
#   all checks OK      -> "SUCCESS"                          (exit 0)
#   1-2 checks failed,
#   or any WARN        -> "WARNING" + where to troubleshoot  (exit 1)
#   3+ checks failed   -> "FAILED"  + where to troubleshoot  (exit 2)
#
# A missing/stopped instance means no checks can run at all, so that is
# reported as "ERROR" (exit 3) rather than as a failed check.
#
# WARN means a check couldn't be confirmed yet for a reason provisioning can't
# fix: a passphrase-protected GitHub key that isn't unlocked in ssh-agent.
# Unlock it (ssh-add in a VM shell) and re-run.
#
# SKIP is not a failure: the secrets/SSH checks only apply once
# initialize_secrets.sh exists (see README step 2).

VMNAME="${1:-}"
if [ -z "$VMNAME" ]; then
  echo "ERROR: usage: $0 <VMNAME>" >&2
  exit 3
fi

STATUS="$(limactl list "$VMNAME" --format '{{.Status}}' 2>/dev/null)"
if [ -z "$STATUS" ]; then
  echo "ERROR: no Lima instance named '$VMNAME' - check 'limactl list'" >&2
  exit 3
fi
if [ "$STATUS" != "Running" ]; then
  echo "ERROR: instance '$VMNAME' is not running (status: $STATUS) - run: limactl start $VMNAME" >&2
  exit 3
fi

# Everything below runs as ONE remote script over a single SSH round-trip.
# Captured via a single-quoted heredoc so $VAR/$() are expanded by the
# GUEST's zsh, not by this local script.
#
# Each check prints its own "name ... OK|WARN|FAIL|SKIP" line as it runs (so a
# slow check like `docker run` doesn't look like a hang), and a failure or
# warning additionally emits a machine-readable `__FAIL__<name>|<where to look>`
# or `__WARN__<name>|<what to do>` line that the host side filters out of the
# live output and turns into the closing summary.
read -r -d '' REMOTE_SCRIPT << 'EOF'
NAME_WIDTH=28

ok()   { printf "%-${NAME_WIDTH}s ... OK\n"   "$1"; }
skip() { printf "%-${NAME_WIDTH}s ... SKIP\n" "$1"; }
warn() { printf "%-${NAME_WIDTH}s ... WARN\n" "$1"; printf '__WARN__%s|%s\n' "$1" "$2"; }
bad()  { printf "%-${NAME_WIDTH}s ... FAIL\n" "$1"; printf '__FAIL__%s|%s\n' "$1" "$2"; }

# chk <name> <where-to-look> <command...>
# The command is run directly (not eval'd); wrap pipelines in a function.
chk() {
  local name="$1" where="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name" "$where"; fi
}

VM_YAML=".limavm/ubuntu24-docker.yaml"

chk "ubuntu 24.04 guest" "$VM_YAML (base: order / image pin)" \
  grep -q 'VERSION_ID="24.04"' /etc/os-release

# The guest paths are fixed by the yaml's `mounts:`; only the Mac side varies.
chk "project mount /workspaces" "$VM_YAML (mounts: / param.project)" \
  mountpoint -q /workspaces
chk "lima-workflow mount" "$VM_YAML (mounts: / param.limaWorkflowDir)" \
  test -d /opt/lima-workflow/provision
# Read-only so nothing in the VM can edit the scripts that run as root.
lima_workflow_readonly() { findmnt -no OPTIONS /opt/lima-workflow | tr ',' '\n' | grep -qx ro; }
chk "lima-workflow read-only" "$VM_YAML (mounts: writable: false)" \
  lima_workflow_readonly
# template:docker brings in Lima's default read-only mount of the whole Mac
# $HOME; `limactl create --set ...` strips it. /mnt/lima-* are Lima's own
# (e.g. Rosetta), not shared folders.
no_extra_mounts() {
  ! findmnt -rn -t virtiofs -o TARGET \
    | grep -vxE '/workspaces|/opt/lima-workflow|/mnt/lima-.*' | grep -q .
}
chk "no other shared folders" "limactl create --set '.mounts |= ...' (README step 3)" \
  no_extra_mounts

for c in git gh az azd python3 pipx zsh jq direnv op; do
  chk "command: $c" "provision/00-system-packages.sh (mode: system)" \
    command -v "$c"
done

# Check oh-my-zsh.sh (the file .zshrc sources), not just ~/.oh-my-zsh: a failed
# install leaves the directory behind (10-user-shell.sh's zsh-autosuggestions
# clone creates custom/plugins/... under it), so a -d test false-passes here and
# the real breakage only surfaces as the theme check below.
chk "oh-my-zsh installed" "provision/10-user-shell.sh (oh-my-zsh clone)" \
  test -f "$HOME/.oh-my-zsh/oh-my-zsh.sh"
chk "zsh theme (edvardm)" "provision/10-user-shell.sh (.zshrc ZSH_THEME handling)" \
  grep -q 'ZSH_THEME="edvardm"' "$HOME/.zshrc"
chk "zsh plugins" "provision/10-user-shell.sh (.zshrc plugins handling)" \
  grep -q '^plugins=(git docker ssh-agent npm zsh-autosuggestions)' "$HOME/.zshrc"
chk "login shell is zsh" "provision/10-user-shell.sh (chsh step)" \
  test "$(getent passwd "$(whoami)" | cut -d: -f7)" = "$(command -v zsh)"

chk "command: terraform" "provision/20-user-tools.sh (tfenv) / .zshrc PATH line" \
  command -v terraform
chk "command: node" "provision/20-user-tools.sh (nvm) / .zshrc nvm init block" \
  command -v node
chk "command: aws" "provision/20-user-tools.sh (aws-cli)" \
  command -v aws
# Resolved through PATH, like claude below: catches both a failed
# `az bicep install` and the ~/.azure/bin PATH line missing from .zshrc.
chk "command: bicep" "provision/20-user-tools.sh (az bicep install) / .zshrc ~/.azure/bin PATH line" \
  command -v bicep
# Resolved through PATH on purpose: the launcher existing on disk is not the
# failure mode worth catching - it is the ~/.local/bin PATH line missing from
# .zshrc, which leaves `claude` installed but unreachable in the guest shell.
chk "command: claude" "provision/20-user-tools.sh (Claude Code) / .zshrc ~/.local/bin PATH line" \
  command -v claude
chk "command: pre-commit" "provision/20-user-tools.sh (pipx install pre-commit)" \
  command -v pre-commit
# The binary is checked in the mode:system loop above; this checks the half that
# can go missing on its own. Without the hook direnv is installed but inert, and
# `command -v direnv` still passes - so that check alone would not notice.
direnv_hook_loaded() { typeset -f _direnv_hook >/dev/null 2>&1; }
chk "direnv hook in zsh" "provision/20-user-tools.sh (.zshrc direnv hook line)" \
  direnv_hook_loaded
# Without this, https remotes on the shared mount prompt for a username
# forever, however good the installed SSH key is.
chk "git https->ssh rewrite" "provision/30-user-profile.sh (git insteadOf)" \
  git config --global --get 'url.git@github.com:.insteadOf'

# initialize_secrets.sh is per project and optional, so it may legitimately
# not exist yet - skip rather than fail (see README step 2).
SECRETS_SCRIPT="/workspaces/.limavm/initialize_secrets.sh"
if [ -f "$SECRETS_SCRIPT" ]; then
  chk "~/.ssh/config present" "initialize_secrets.sh (SSH section)" \
    test -f "$HOME/.ssh/config"

  # A passphrase-protected key can't be unlocked here (there's no terminal to
  # type into), so it only authenticates once it's loaded in ssh-agent. Until
  # then GitHub answering "Server accepts key" shows the key is registered and
  # the host key trusted, but login itself is unconfirmed - hence WARN.
  GH_SSH="$(ssh -o BatchMode=yes -o ConnectTimeout=8 -vT git@github.com 2>&1)"
  if grep -q "successfully authenticated" <<< "$GH_SSH"; then
    ok "github ssh authenticates"
  elif grep -q "Server accepts key" <<< "$GH_SSH"; then
    warn "github ssh authenticates" "key has a passphrase and isn't unlocked: run ssh-add in a VM shell, then re-run"
  else
    bad "github ssh authenticates" "initialize_secrets.sh key + 30-user-profile.sh known_hosts pre-seed"
  fi
  # A rebuilt VM has no ~/.gitconfig, and git refuses to commit without an
  # identity - so this has to come from provisioning, not a manual one-off.
  chk "git identity set" "initialize_secrets.sh (Setup Git identity section)" \
    git var GIT_AUTHOR_IDENT
else
  skip "~/.ssh/config present"
  skip "github ssh authenticates"
  skip "git identity set"
fi

docker_hello_world() { docker run --rm hello-world 2>&1 | grep -q "Hello from Docker"; }
chk "docker hello-world" "template:docker provisioning (dockerd-rootless)" \
  docker_hello_world

echo "__DONE__"
EOF

RESULTS="$(mktemp -t limavm-verify)"
trap 'rm -f "$RESULTS"' EXIT

# Stream the checks to the terminal as they run while keeping a full copy for
# the summary. --line-buffered so the greps don't hold the report back.
# --workdir: limactl shell otherwise tries to cd into the Mac's current
# directory, which doesn't exist in the guest (only the project folder and
# lima-workflow are mounted), and prints a `cd: ... No such file` error.
# SSH_ASKPASS*: oh-my-zsh's ssh-agent plugin runs ssh-add as the shell starts,
# which would print a passphrase prompt nobody can answer into the report.
# A failing askpass makes it give up silently; the key stays locked.
limactl shell --workdir /workspaces "$VMNAME" -- \
  env SSH_ASKPASS_REQUIRE=force SSH_ASKPASS=/bin/false \
  zsh -ic "$REMOTE_SCRIPT" 2>&1 \
  | grep --line-buffered -v 'Starting ssh-agent' \
  | tee "$RESULTS" \
  | grep --line-buffered -v '^__FAIL__\|^__WARN__\|^__DONE__'

if ! grep -q '^__DONE__' "$RESULTS"; then
  echo "" >&2
  echo "ERROR: checks did not run to completion in '$VMNAME' - is it still booting? (limactl shell $VMNAME)" >&2
  exit 3
fi

FAIL_COUNT="$(grep -c '^__FAIL__' "$RESULTS")"
WARN_COUNT="$(grep -c '^__WARN__' "$RESULTS")"

echo ""
if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
  echo "SUCCESS"
  exit 0
fi

# 1-2 failures is usually one provisioning step to re-run; 3+ means the run
# broke early enough to take later steps down with it. Warnings alone are
# never worse than WARNING.
if [ "$FAIL_COUNT" -gt 2 ]; then
  echo "FAILED"
  VERDICT=2
else
  echo "WARNING"
  VERDICT=1
fi

while IFS='|' read -r name where; do
  printf '%-28s ... FAILED see %s\n' "${name#__FAIL__}" "$where"
done < <(grep '^__FAIL__' "$RESULTS")
while IFS='|' read -r name todo; do
  printf '%-28s ... WARN   %s\n' "${name#__WARN__}" "$todo"
done < <(grep '^__WARN__' "$RESULTS")

# Re-provisioning fixes failures, not warnings.
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo ""
  echo "Provisioning detail: limactl shell --workdir /workspaces $VMNAME -- sudo less /var/log/cloud-init-output.log"
  echo "Re-run provisioning:  limactl stop $VMNAME && limactl start $VMNAME"
fi
exit "$VERDICT"
