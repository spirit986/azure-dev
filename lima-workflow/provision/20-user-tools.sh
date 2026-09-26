#!/bin/bash
set -eux -o pipefail
# Lima provisioning script — mode: user (runs as the guest user, on every boot).
#
# aws-cli, tfenv+terraform, Bicep, node (via nvm), Claude Code, pre-commit,
# and direnv's shell hook.
#
# Idempotent: each tool is guarded by an existence check; tfenv install/use
# and `nvm install --lts` are no-ops if the version is already present.

# --- aws-cli ---
# Installed but deliberately left unconfigured: no profiles, no AWS_PROFILE.
if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  sudo /tmp/aws/install --update
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi

# --- tfenv + Terraform (latest) ---
if [ ! -d "$HOME/.tfenv" ]; then
  git clone --depth=1 https://github.com/tfutils/tfenv.git "$HOME/.tfenv"
fi

TFENV_PATH_LINE='export PATH="$HOME/.tfenv/bin:$PATH"'
grep -qxF "$TFENV_PATH_LINE" "$HOME/.zshrc" 2>/dev/null || echo "$TFENV_PATH_LINE" >> "$HOME/.zshrc"

export PATH="$HOME/.tfenv/bin:$PATH"
# Not pinned: every boot moves to the newest release (a no-op when already on
# it). That needs releases.hashicorp.com, so if the lookup fails but some
# version is already installed, keep that one rather than failing the boot.
if tfenv install latest; then
  tfenv use latest
elif tfenv version-name >/dev/null 2>&1; then
  echo "warning: could not reach releases.hashicorp.com - keeping Terraform $(tfenv version-name)" >&2
else
  exit 1
fi

# --- Bicep (Azure's IaC language; `az` itself comes from 00-system-packages.sh) ---
# `az bicep install` puts the binary at ~/.azure/bin/bicep, which is where
# `az deployment ... --template-file x.bicep` looks for it. Putting that
# directory on PATH also makes the standalone `bicep` command (bicep build,
# bicep lint, bicep decompile) available. Guarded on the binary so later boots
# don't need github.com; upgrade by hand with `az bicep upgrade`.
if [ ! -x "$HOME/.azure/bin/bicep" ]; then
  az bicep install
fi

AZURE_BIN_PATH_LINE='export PATH="$HOME/.azure/bin:$PATH"'
grep -qxF "$AZURE_BIN_PATH_LINE" "$HOME/.zshrc" 2>/dev/null || echo "$AZURE_BIN_PATH_LINE" >> "$HOME/.zshrc"

# --- node, via nvm ---
# Installed by cloning the tag (nvm's documented manual install) rather than by
# piping install.sh from raw.githubusercontent.com — that host fails
# independently of github.com and served HTTP 429 for hours during the GitHub
# incident on 2026-08-17, aborting provisioning here before 30-user-profile.sh
# ever ran. See the longer note in 10-user-shell.sh.
#
# NOTE: cloning also sidesteps what install.sh would get wrong anyway: it picks
# the rc file to wire itself into by inspecting $SHELL, which under
# non-interactive provisioning is the shell that invoked this script (bash),
# not the account's zsh login shell — so it wrote its init block into .bashrc
# regardless of the account's real shell. We append the standard nvm init block
# to .zshrc ourselves so `node`/`nvm` are available in the zsh sessions this VM
# actually uses (grep-guarded, so re-running doesn't duplicate it).
NVM_VERSION="v0.40.1"
# Guard on nvm.sh, not the directory: a half-finished clone would otherwise
# make this a permanent no-op on every later boot.
if [ ! -s "$HOME/.nvm/nvm.sh" ]; then
  rm -rf "$HOME/.nvm"
  git clone --depth 1 --branch "$NVM_VERSION" https://github.com/nvm-sh/nvm.git "$HOME/.nvm"
fi

NVM_INIT_MARKER='export NVM_DIR="$HOME/.nvm"'
if ! grep -qF "$NVM_INIT_MARKER" "$HOME/.zshrc" 2>/dev/null; then
  cat >> "$HOME/.zshrc" <<'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
EOF
fi

export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
nvm install --lts
nvm alias default 'lts/*'

# --- Claude Code ---
# Anthropic's native installer, the documented and recommended route on Linux:
# it drops a launcher at ~/.local/bin/claude symlinked into
# ~/.local/share/claude/versions/, and keeps itself updated in the background
# from then on. So this is a first-install step, not an upgrade step — nothing
# here needs to re-run once the launcher exists.
#
# Piping an installer from the network is the thing 10-user-shell.sh and the
# nvm block above deliberately avoid, but the reasoning doesn't carry over:
# what they avoid is raw.githubusercontent.com specifically (it fails
# independently of github.com — HTTP 429 for hours during the 2026-08-17
# incident — while the git clone it fronted worked fine, so cloning removed a
# whole failure domain for free). There is no equivalent way to fetch this
# binary; claude.ai is the only source, exactly like aka.ms for the Azure CLI
# in 00-system-packages.sh. Hence the same mitigation used there: -f so an
# HTTP error page is never piped to bash as if it were a script, plus retries.
#
# Not installed via `npm install -g @anthropic-ai/claude-code`, even though
# nvm/node is right above: an nvm global install is scoped to one Node version
# and silently disappears the next time `nvm install --lts` moves the LTS
# line. The native install has no Node dependency at all (the npm package just
# vendors the same native binary).
#
# Guard on the launcher being executable rather than `command -v claude`: this
# script runs non-interactively under bash, where ~/.local/bin isn't on PATH
# yet, so command -v would miss an existing install and re-run the installer on
# every boot. `-x` also follows the symlink, so a dangling launcher (versions/
# wiped, launcher left behind) correctly re-installs instead of being treated
# as present.
if [ ! -x "$HOME/.local/bin/claude" ]; then
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
    https://claude.ai/install.sh | bash
fi

# The installer's own PATH wiring can't be relied on here: like nvm's, it picks
# a shell rc file from $SHELL, which under non-interactive provisioning is bash
# rather than this account's zsh login shell. Ubuntu's ~/.profile does add
# ~/.local/bin, but zsh never reads .profile — so without this line `claude`
# is missing from exactly the interactive zsh sessions this VM is used through.
LOCAL_BIN_PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
grep -qxF "$LOCAL_BIN_PATH_LINE" "$HOME/.zshrc" 2>/dev/null || echo "$LOCAL_BIN_PATH_LINE" >> "$HOME/.zshrc"

# ...and for the rest of THIS script too, the way the tfenv block above does:
# the pipx install below puts its entry point in the same directory.
export PATH="$HOME/.local/bin:$PATH"

# --- pre-commit ---
# Git hook framework: runs the linters/formatters a repo lists in its
# .pre-commit-config.yaml on every commit. Only the binary is installed;
# no hooks are installed into any repo.
#
# Via pipx rather than pip: Ubuntu 24.04 marks its system Python
# externally-managed (PEP 668), so `pip install --user pre-commit` is refused
# outright. pipx is already installed by 00-system-packages.sh and drops the
# entry point in ~/.local/bin, which the PATH line just above covers.
#
# Guarded like every other step here, so re-provisioning on boot doesn't need
# PyPI to be reachable.
if [ ! -x "$HOME/.local/bin/pre-commit" ]; then
  pipx install pre-commit
fi

# --- direnv shell hook (the binary comes from 00-system-packages.sh) ---
# `apt install direnv` deliberately doesn't touch your shell rc, and direnv does
# nothing at all until its hook is in there — so the apt package on its own
# would look installed and behave as if it weren't.
#
# Appended here rather than in 10-user-shell.sh because that script REPLACES
# .zshrc wholesale when it (re)installs oh-my-zsh: anything appended there in
# the same pass would be thrown away. Appending also puts the hook *after* the
# `source .../oh-my-zsh.sh` line, which is the ordering direnv's docs ask for —
# the hook registers a precmd, and oh-my-zsh rewires precmd as it loads, so a
# hook evaluated before it gets shadowed. (30-user-profile.sh appends after
# this, but only a plain `export`, which doesn't touch precmd.)
DIRENV_HOOK_LINE='eval "$(direnv hook zsh)"'
grep -qxF "$DIRENV_HOOK_LINE" "$HOME/.zshrc" 2>/dev/null || echo "$DIRENV_HOOK_LINE" >> "$HOME/.zshrc"
