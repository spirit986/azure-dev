#!/bin/bash
set -u
# Post-provisioning smoke test for a Lima VM built from
# ubuntu24-docker.yaml. Run this after `limactl start <VMNAME>` to
# confirm provisioning actually completed instead of eyeballing it.
#
# Usage: ./limavm-verify.sh <VMNAME>
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
#   1-2 checks failed  -> "WARNING" + where to troubleshoot  (exit 1)
#   3+ checks failed   -> "FAILED"  + where to troubleshoot  (exit 2)
#
# A missing/stopped instance means no checks can run at all, so that is
# reported as "ERROR" (exit 3) rather than as a failed check.
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
# Each check prints its own "name ... OK|FAIL|SKIP" line as it runs (so a slow
# check like `docker run` doesn't look like a hang), and a failure additionally
# emits a machine-readable `__FAIL__<name>|<where to look>` line that the host
# side filters out of the live output and turns into the closing summary.
read -r -d '' REMOTE_SCRIPT << 'EOF'
NAME_WIDTH=28

ok()   { printf "%-${NAME_WIDTH}s ... OK\n"   "$1"; }
skip() { printf "%-${NAME_WIDTH}s ... SKIP\n" "$1"; }
bad()  { printf "%-${NAME_WIDTH}s ... FAIL\n" "$1"; printf '__FAIL__%s|%s\n' "$1" "$2"; }

# chk <name> <where-to-look> <command...>
# The command is run directly (not eval'd); wrap pipelines in a function.
chk() {
  local name="$1" where="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name" "$where"; fi
}

VM_YAML="ubuntu24-docker.yaml"

chk "ubuntu 24.04 guest" "$VM_YAML (base: order / image pin)" \
  grep -q 'VERSION_ID="24.04"' /etc/os-release

# Locate the workspace mount before anything that depends on it. Not a plain
# chk because the discovered path is reused by the secrets checks below.
# Globbed rather than built from param.repoDir, which this script can't see;
# (N) is zsh's null-glob, so a mount without a match expands to nothing.
PROVISION_DIR=""
while read -r _ _ mp _; do
  for d in "$mp"/*/lima-workflow/provision(N); do
    PROVISION_DIR="$d"
    break 2
  done
done < <(mount | grep virtiofs)
chk "provision dir on virtiofs" "$VM_YAML (mounts: / param.project / param.repoDir)" \
  test -n "$PROVISION_DIR"

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

# initialize_secrets.sh is gitignored and per-VM, so it may legitimately not
# exist yet - skip rather than fail (see README step 2).
SECRETS_SCRIPT="$PROVISION_DIR/../initialize_secrets.sh"
if [ -n "$PROVISION_DIR" ] && [ -f "$SECRETS_SCRIPT" ]; then
  github_ssh_authenticates() {
    ssh -o BatchMode=yes -o ConnectTimeout=8 -T git@github.com 2>&1 \
      | grep -q "successfully authenticated"
  }

  chk "~/.ssh/config present" "initialize_secrets.sh (SSH section)" \
    test -f "$HOME/.ssh/config"
  chk "github ssh authenticates" "initialize_secrets.sh key + 30-user-profile.sh known_hosts pre-seed" \
    github_ssh_authenticates
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
limactl shell "$VMNAME" -- zsh -ic "$REMOTE_SCRIPT" 2>&1 \
  | grep --line-buffered -v 'Starting ssh-agent' \
  | tee "$RESULTS" \
  | grep --line-buffered -v '^__FAIL__\|^__DONE__'

if ! grep -q '^__DONE__' "$RESULTS"; then
  echo "" >&2
  echo "ERROR: checks did not run to completion in '$VMNAME' - is it still booting? (limactl shell $VMNAME)" >&2
  exit 3
fi

FAIL_COUNT="$(grep -c '^__FAIL__' "$RESULTS")"

echo ""
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "SUCCESS"
  exit 0
fi

# 1-2 failures is usually one provisioning step to re-run; 3+ means the run
# broke early enough to take later steps down with it.
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

echo ""
echo "Provisioning detail: limactl shell $VMNAME -- sudo less /var/log/cloud-init-output.log"
echo "Re-run provisioning:  limactl stop $VMNAME && limactl start $VMNAME"
exit "$VERDICT"
