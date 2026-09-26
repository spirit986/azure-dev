# Concept

Useful for a Mac with an M1+ chip (ARM architecture).

The idea is a dedicated Lima VM with Docker per project, sharing the project
folder with your Mac. A *project* is everything that belongs to one client or
task: a folder under `~/Projects` holding any number of repos plus other files.
The folder itself usually isn't a repo. You edit on the Mac and run containers
and cloud tooling (Azure CLI, Bicep, Terraform) inside the VM, which you can
create and destroy at will.

## How it works

The VM is meant to be disposable. You create the project's config from
`ubuntu24-docker.yaml.example`, optionally fill in its secrets from
`initialize_secrets.sh.example`, and run the [Quickstart](#0-quickstart).

The provisioning scripts take a few minutes on first boot (about 3–5 min), so
don't rebuild the VM unless you need to. Restarting it re-runs provisioning,
but that's much faster because everything is already installed.

Anything you want to keep lives in the shared project folder on the Mac. The
VM itself holds only tools and logins, so you can rebuild it at any time.

The VM has its own Docker engine. Use `docker context` to switch the Mac's
`docker` CLI between it, Docker Desktop, or other Lima VMs.

## One template, many projects

Everything in `lima-workflow/` is project-agnostic, and you keep **one copy**
of this repo for all your projects. Each project gets its own VM, and its own
config and secrets in a `.limavm/` folder inside the project folder, so each
client can have a different GitHub key and git identity. Throughout this
README:

| placeholder | meaning | Azure workshop example |
|---|---|---|
| `myvm` | Lima instance name (`limactl create --name=...`) | `azuredev` |
| `my-project` | project folder under `~/Projects` (`param.project`) | `azure-workshop` |
| `devuser` | Linux user inside the VM (`user.name`) | `tomspirit` |
| `~/Projects/azure-dev` | where this repo is cloned (`param.limaWorkflowDir` points at its `lima-workflow/`) | `~/Projects/azure-workshop/azure-dev` |

```
Mac                                        Guest (VM)
~/Projects/my-project/                     /workspaces/          read-write
├── .limavm/                               ├── .limavm/
│   ├── ubuntu24-docker.yaml               │     this VM's config
│   └── initialize_secrets.sh              │     this client's secrets (optional)
├── repo-a/                                ├── repo-a/
└── repo-b/                                └── repo-b/

~/Projects/azure-dev/lima-workflow/        /opt/lima-workflow/   read-only
                                             provision scripts, run on every boot
```

Repos appear directly under `/workspaces`, whether you clone them on the Mac
or inside the VM. The tools are installed system-wide or into the VM user's
home, never per repo, so any number of repos can share them.

`lima-workflow` is mounted read-only so nothing running inside the VM can
change the scripts that run as root on the next boot. Edit them on the Mac.

The azure-dev repo can live anywhere on the Mac, inside a project folder or
not. `param.limaWorkflowDir` tells each VM where to find it.

A native ARM64 **Ubuntu 24.04** VM, with Rosetta enabled so you can still run
amd64-only containers at near-native speed. It runs Docker and shares exactly
one folder with the Mac via virtiofs: you edit it from VS Code on the Mac and
run it with `docker compose` inside the VM. The VM also provisions itself
automatically on every boot with a dev toolchain: see
[What gets installed automatically](#what-gets-installed-automatically).

> Why ARM64 + Rosetta instead of a "real" x86_64 guest: Apple's
> Virtualization.framework (`vz`) only runs guests matching the host
> architecture. A true x86_64 Ubuntu on an M1 would have to fall back to
> QEMU's full software CPU emulation — usable, but 5-10x slower across the
> board. Rosetta instead translates just the amd64 *binaries inside
> containers* on top of a native ARM64 kernel, which is dramatically faster
> for the "I just need this one amd64 image to run" case.

> Why pin 24.04 specifically: Lima's `docker` template tracks whatever the
> current Ubuntu LTS is (`ubuntu-lts`) — that alias moved to 26.04 in April
> 2026. Pinning to `ubuntu-24.04` explicitly keeps you off that rolling
> target. This is easy to get subtly wrong — see the gotcha in
> [step 3](#3-create-the-lima-instance) before you touch the `base:` list.

---

## 0. Quickstart

The condensed version, for getting going fast or re-provisioning from
scratch. Each step is explained in full further down — read those if
anything here doesn't make sense or doesn't work.

```bash
# 1. Prerequisites
brew install lima docker docker-compose docker-buildx
softwareupdate --install-rosetta --agree-to-license

# 2. This repo drives the whole setup - clone it once, for all projects
#    (skip if you already have it)
git clone git@github.com:spirit986/azure-dev.git ~/Projects/azure-dev

# 3. The project's config + secrets, from the checked-in templates
mkdir -p ~/Projects/my-project/.limavm
cd ~/Projects/my-project/.limavm
cp ~/Projects/azure-dev/lima-workflow/ubuntu24-docker.yaml.example ubuntu24-docker.yaml
cp ~/Projects/azure-dev/lima-workflow/initialize_secrets.sh.example initialize_secrets.sh \
  && chmod 600 initialize_secrets.sh   # optional
# now edit both files:
#  - ubuntu24-docker.yaml: set param.project, param.limaWorkflowDir and user.name/user.home
#  - initialize_secrets.sh: this client's GitHub SSH key + git identity.
#    NEVER commit this file.

# 4. Create + start the VM (sizing/engine flags are baked into the yaml;
#    the --set strips Lima's default mount of your whole $HOME - see step 3)
limactl create --name=myvm --set '.mounts |= map(select(.location != "~"))' ubuntu24-docker.yaml
limactl start myvm

# 5. Verify everything actually provisioned correctly
~/Projects/azure-dev/lima-workflow/limavm-verify.sh myvm
# -> per-check "name ... OK/FAIL" lines, then SUCCESS / WARNING / FAILED

# 6. Point your Mac's docker CLI at the VM
docker context create lima-myvm --docker "host=unix://$HOME/.lima/myvm/sock/docker.sock"
docker context use lima-myvm

# 7. Log in to Azure inside the VM (once per VM - survives restarts)
limactl shell --workdir /workspaces myvm zsh -ic 'az login --use-device-code'
```

If `limavm-verify.sh` prints `SUCCESS`, you're done — jump to
[Day-to-day commands](#11-day-to-day-commands). If any check fails, each one
points at roughly the right place (which provisioning script, which config); the
[Troubleshooting](#troubleshooting) section below has the specific gotchas
this setup has already hit once each.

The VM's login shell is `zsh`. To get a shell inside the VM:
```bash
limactl shell --workdir /workspaces myvm zsh
```

`--workdir /workspaces` is there because `limactl shell` otherwise tries to
`cd` into your current Mac folder inside the VM. Only the project folder is
shared, so from anywhere else you'd get a harmless
`cd: /Users/...: No such file or directory` and land in the VM user's home. A
Mac alias saves the typing:
```bash
# ~/.zshrc on the Mac
alias myvm='limactl shell --workdir /workspaces myvm zsh'
```

If your GitHub key in `initialize_secrets.sh` has a passphrase, the first
shell after each VM start asks for it (oh-my-zsh's `ssh-agent` plugin), and
the key stays unlocked until the VM stops.

---

## 1. Prerequisites

```bash
# Lima itself (installs the docker CLI too, if you don't already have it)
brew install lima docker docker-compose docker-buildx
```

- macOS 13 (Ventura) or later — needed for `vz` (Apple's Virtualization.framework),
  which gives near-native performance and virtiofs support.
- If you still have Docker Desktop installed, that's fine — see
  [step 10](#10-coexisting-with-docker-desktop-and-other-lima-vms).

Make sure Rosetta is installed on the Mac itself (harmless if it already is):

```bash
softwareupdate --install-rosetta --agree-to-license
```

Clone this repo once, if you don't have it yet. Every project's VM reads its
provision scripts from this one copy through a read-only mount, so it has to
exist before you create a VM. It can go anywhere; this README assumes
`~/Projects/azure-dev`:

```bash
git clone git@github.com:spirit986/azure-dev.git ~/Projects/azure-dev
```

Because the VM mounts this folder by its Mac path, moving the repo later
breaks the mount for existing VMs. Update the path with `limactl edit myvm`
(the second entry under `mounts:`) or recreate the VM.

---

## 2. Create the project's VM config + secrets files

Two files are checked in to `lima-workflow/` as `*.example` templates only.
The working copies belong to the project, not to this repo, so they go in the
project's `.limavm/` folder. That's how one copy of this repo serves several
clients, each with its own VM settings, GitHub key and git identity:

```bash
mkdir -p ~/Projects/my-project/.limavm
cd ~/Projects/my-project/.limavm
cp ~/Projects/azure-dev/lima-workflow/ubuntu24-docker.yaml.example ubuntu24-docker.yaml
cp ~/Projects/azure-dev/lima-workflow/initialize_secrets.sh.example initialize_secrets.sh
chmod 600 initialize_secrets.sh
```

**`ubuntu24-docker.yaml`** — the Lima instance template. Everything
project-specific is in the block at the top:

- `param.project` — the project folder's name under `~/Projects`. The whole
  folder is shared with the VM as `/workspaces`.
- `param.limaWorkflowDir` — where this repo's `lima-workflow/` folder is on
  the Mac, e.g. `~/Projects/azure-dev/lima-workflow`. It's mounted read-only
  at `/opt/lima-workflow`, and the provision steps run from there.
- `user.name` / `user.home` — pick a valid Linux username. Dotted Mac
  usernames (e.g. `jane.doe`) fail Linux's username validation
  (`^[a-z_][a-z0-9_-]*$`), and Lima silently falls back to a generic `lima`
  account if you don't set this explicitly. `limactl create` still prints a
  warning about your Mac username (`using lima instead`) even when this is
  set; that's harmless, and the VM uses the name from the yaml.

Everything else (VM sizing, Rosetta, mount type, provisioning) already has
sane defaults — you shouldn't need to touch it for normal use.

**`initialize_secrets.sh`** (optional) — runs inside the VM on every boot and
sets up a GitHub SSH key + `~/.ssh/config` and your git identity
(`user.name` / `user.email`). It also has a commented-out block for a Terraform
Cloud token, if a project needs one. Azure credentials are deliberately *not*
in here — see [step 5](#5-log-in-to-azure).

Use the email of the GitHub account whose SSH key you put in this file, so
commits you make inside the VM are attributed to you. The identity has to be
set here rather than by hand: a rebuilt VM starts with no `~/.gitconfig`, and
git refuses to commit without one (`unable to auto-detect email address`).

> ⚠️ **This file holds live credentials in plaintext.** It lives outside this
> repo on purpose. If the project folder is itself a git repo (a multi-repo
> checkout), add `.limavm/initialize_secrets.sh` to that repo's `.gitignore`.
> The VM can read it at `/workspaces/.limavm/`, like everything else in the
> project folder. If you ever suspect it leaked (committed, pasted somewhere,
> read by a tool you don't trust), rotate the SSH key (and the Terraform
> token, if you set one) rather than assuming it's fine.

If you skip this file entirely, the VM still provisions fine. The secrets
step just no-ops with a note, and `limavm-verify.sh` skips the
secrets/GitHub-SSH checks instead of failing on them.

---

## 3. Create the Lima instance

```bash
cd ~/Projects/my-project/.limavm
limactl create --name=myvm --set '.mounts |= map(select(.location != "~"))' ubuntu24-docker.yaml
limactl start myvm
```

> ⚠️ **Don't leave out the `--set`.** `template:docker` (in the yaml's
> `base:` list) pulls in Lima's default mount of your whole Mac `$HOME`,
> read-only. Lima merges a base template's list entries into yours, and the
> yaml has no way to delete one. Without the `--set`, every client VM could
> read your `~/.ssh` and all your other projects. The filter drops that one
> entry at create time. The result is frozen into the instance, so it holds
> across restarts. `limavm-verify.sh` fails its `no other shared folders`
> check if the mount is there. To fix an existing VM, delete the `~` entry
> with `limactl edit myvm`.

That's the only extra flag needed. The VM sizing and engine settings you'd
normally pass to `limactl create` (`--vm-type`, `--mount-type`, `--rosetta`,
`--cpus`, `--memory`, `--disk`) are already declared in the yaml:

| yaml field | equivalent flag | why |
|---|---|---|
| `vmType: vz` | `--vm-type=vz` | Apple's Virtualization.framework instead of QEMU — native ARM64, faster boot, best virtiofs performance. |
| `mountType: virtiofs` | `--mount-type=virtiofs` | Fast, near-native file sharing (vs. the slower default `reverse-sshfs`). |
| `vmOpts.vz.rosetta.enabled` | `--rosetta` | Enables Rosetta binary translation inside the VM (only works with `vz`), so amd64-only containers run via translation instead of full CPU emulation. |
| `cpus` / `memory` / `disk` | `--cpus` / `--memory` / `--disk` | 4 vCPU / 6 GiB / 40 GiB — enough for a handful of containers, and small enough to run next to another Lima VM on a 16 GB Mac. The disk is sparse, so it only uses what's written. Change later with `limactl edit myvm` (see the gotcha under [step 11](#11-day-to-day-commands) first). |
| `mounts:` | `--mount-only ...` | The yaml declares the two shared folders directly: the project folder at `/workspaces` (read-write) and `lima-workflow` at `/opt/lima-workflow` (read-only). The `--set` above removes Lima's default `$HOME` mount. |

> ⚠️ **Gotcha: `base:` list order controls which Ubuntu version you actually
> get, and it's easy to get backwards.** `base: [template:docker,
> template:_images/ubuntu-24.04]` looks like it should pin 24.04, but it
> doesn't — Lima *concatenates* the `images:` lists from every `base:` entry
> rather than letting a later entry override an earlier one, and
> `template:docker` itself already pulls in the rolling `ubuntu-lts` alias
> (now 26.04) as part of *its own* base chain. Since that ends up first in
> the merged list, 26.04 wins as the first architecture match — 24.04 never
> gets tried. The checked-in yaml has this the correct way round:
> `base: [template:_images/ubuntu-24.04, template:docker]`. If you ever touch
> the `base:` list, re-run `limactl create` and check the log line
> `Attempting to download the image` — it should say `ubuntu-24.04`, not
> `ubuntu-26.04`, and `limavm-verify.sh` checks this too.

To check a config before creating anything, `limactl template validate --fill
ubuntu24-docker.yaml` prints the fully resolved yaml. The `mounts:` lines show
exactly what your params expand to. They also include the inherited `$HOME`
entry, because `validate` doesn't apply the `--set`.

First boot takes a few minutes — it's downloading the base image, installing
Docker, and running everything under `lima-workflow/provision/`.

---

## 4. Verify provisioning succeeded

Don't just eyeball it — run the check script, which exercises everything the
provisioning is supposed to have set up (OS version, shared mounts, system
packages, zsh/oh-my-zsh, Terraform, node, the Azure/AWS CLIs, Bicep, Claude
Code, secrets if configured, and Docker itself):

```bash
~/Projects/azure-dev/lima-workflow/limavm-verify.sh myvm
```

Every check reports itself as it runs, then the script prints a verdict:

```
ubuntu 24.04 guest           ... OK
project mount /workspaces    ... OK
...
zsh theme (edvardm)          ... FAIL
...

WARNING
zsh theme (edvardm)          ... FAILED see provision/10-user-shell.sh (.zshrc ZSH_THEME handling)
```

| verdict | meaning | exit |
|---|---|---|
| `SUCCESS` | every check passed — the VM is genuinely ready to use | 0 |
| `WARNING` | 1–2 checks failed, usually one provisioning step to re-run — or a check reported `WARN` because it can't be confirmed yet (see below) | 1 |
| `FAILED` | 3+ checks failed; the provisioning run likely broke early and took later steps down with it | 2 |
| `ERROR` | the checks couldn't run at all (no such instance, not running, bad usage) | 3 |

It runs all checks rather than stopping at the first failure, so you see the
whole picture at once: a failure early in provisioning usually breaks several
later things too. `SKIP` is not a failure (see the
[secrets note](#troubleshooting)). `WARN` isn't a provisioning failure
either, but the check couldn't be confirmed: currently only
`github ssh authenticates`, when your GitHub key has a passphrase that hasn't
been entered yet. Unlock it with `ssh-add` in a VM shell and re-run to get
`SUCCESS`.

The `see <...>` pointer names the general area — which `provision/*.sh`
script, or which config — rather than a full diagnosis; treat it as a starting
point, not a root cause. The summary also prints the two commands worth
running next: the guest's `cloud-init-output.log` (where the provision scripts
log every command, since they run with `set -x`) and the stop/start that
re-runs provisioning.

The script checks that the tools are *installed*, not that you're logged in
to anything — it never touches your Azure account.

---

## 5. Log in to Azure

Azure login is interactive and done by hand, once per VM. Nothing in this repo
stores Azure credentials, so the same template works for any tenant or
subscription.

The VM has no browser, so use the device-code flow. It prints a URL and a
code, which you open and enter in the browser on your Mac:

```bash
limactl shell --workdir /workspaces myvm zsh
az login --use-device-code
# a specific tenant (e.g. a workshop/customer tenant rather than your home one):
az login --tenant <tenant-id-or-domain> --use-device-code
```

After login, `az` lists the subscriptions you can see and asks which one to use.
To check or change it later:

```bash
az account list -o table
az account set --subscription "<name-or-id>"
```

The Azure Developer CLI (`azd`) keeps its own login, separate from `az`:

```bash
azd auth login --use-device-code
```

Where the logins live, and how long they last:

- `az` stores its tokens in `~/.azure` and `azd` stores its in `~/.azd`, both
  *inside the VM*. They are not on the shared folder, so credentials never end
  up in your project directory.
- They survive `limactl stop` / `start`, and are lost on `limactl delete`
  (log in again after a rebuild).
- Log out with `az logout` / `azd auth logout`.

**Terraform** (`azurerm` provider) authenticates through the Azure CLI login
automatically. Since `azurerm` v4 it also needs the subscription ID, either as
`subscription_id` in the provider block or as `ARM_SUBSCRIPTION_ID`. A
per-project `.envrc` (see [direnv](#optional-helper-tools)) is a convenient
home for it:

```bash
# <repo>/.envrc
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
```

**Bicep** needs no separate login. `az deployment group create --template-file
main.bicep ...` uses your `az` session, and `bicep build` / `bicep lint` work
offline.

---

## 6. Point the `docker` CLI at it

Lima's docker template prints the exact command on first start, but here it is:

```bash
docker context create lima-myvm \
  --docker "host=unix://$HOME/.lima/myvm/sock/docker.sock"

docker context use lima-myvm
```

Verify with a native ARM64 image:

```bash
docker run --rm hello-world
```

Verify Rosetta acceleration with an amd64 image (add the CDI device flag to actually get Rosetta's speed-up rather than falling back to plain emulation):

```bash
docker run --rm --platform=linux/amd64 --device=lima-vm.io/rosetta=cached hello-world
```

`docker version` should show `linux/arm64` under `Server > OS/Arch` — that's expected; individual containers are what get run through Rosetta via `--platform`, not the engine itself.

---

## 7. Confirm the shared folder is visible

On the Mac:
```bash
touch ~/Projects/my-project/hello-from-mac.txt
```

Inside the VM:
```bash
limactl shell --workdir /workspaces myvm
ls /workspaces
```

Lima's default is to mirror the exact host path (e.g.
`/Users/you/Projects/my-project`). This setup instead mounts the project
folder at a clean, host-independent guest path, `/workspaces`, which matches
the convention VS Code's Dev Containers extension already uses. There's one
project per VM, so its repos sit directly under `/workspaces`.
**Consequence:** any `docker-compose.yml` using *absolute* bind-mount paths
needs to target `/workspaces/<repo>/...` under this VM, not the host path.
Relative bind mounts (`./data:/app/data`) are unaffected either way.

---

## 8. Clone your project repos and run them

Clone into the project folder from either side; the repo shows up on both.

From the Mac:

```bash
cd ~/Projects/my-project
git clone git@github.com:your-org/service-a.git
```

Or from inside the VM, using the SSH key from `initialize_secrets.sh`:

```bash
limactl shell --workdir /workspaces myvm
cd /workspaces
git clone git@github.com:your-org/service-a.git
```

Run the stack from inside the VM:

```bash
limactl shell --workdir /workspaces myvm
cd /workspaces/service-a
docker compose up
```

(You can also just run `docker compose up` directly from your Mac terminal.
Since the `lima-myvm` context is active, the CLI on the Mac talks straight to
the Docker Engine in the VM. `limactl shell` is only needed for a shell
*inside* Ubuntu itself, e.g. for `az`/`terraform`, `htop`, or `docker exec`.)

---

## 9. Edit from VS Code on the Mac

Nothing special needed here — just open `~/Projects/my-project/service-a` as a
normal local folder in VS Code. It's sitting on your Mac's native filesystem;
the VM is just also looking at it through virtiofs.

If any of these repos use the **Dev Containers** extension and you want that
specific repo's container to always build against the Lima engine (regardless
of whatever your global `docker context` is set to), add this to that repo's
`.vscode/settings.json`:

```json
{
  "containers.environment": {
    "DOCKER_HOST": "unix:///Users/<your-mac-username>/.lima/myvm/sock/docker.sock"
  }
}
```

---

## 10. Coexisting with Docker Desktop and other Lima VMs

- Each engine is a separate Linux VM with separate storage: images and
  containers are **not shared** between Docker Desktop and Lima, or between
  two Lima VMs.
- Switch the Mac's CLI between them with `docker context use <name>`
  (`docker context ls` lists them, the active one is marked `*`). Docker
  Desktop's is `desktop-linux`.
- Lima forwards container ports from every running VM to the Mac's
  `localhost`. If two VMs (or a VM and Docker Desktop) publish the same host
  port, the second one to bind will fail. Stop the VM you're not using
  (`limactl stop <other-vm>`) or use distinct port mappings.
- Running two VMs at once also adds up their CPU and memory reservations,
  which is why this template defaults to 4 vCPU / 6 GiB.
- Best practice: quit Docker Desktop (menu bar → Quit) while doing Lima-based
  work, so you're not running an extra VM on the laptop.
- If you hit `exec: "docker-credential-desktop": executable file not found`
  after quitting/removing Desktop (typically on `docker login` or a registry
  pull), either keep Desktop installed (the helper binary just needs to exist
  on disk) or remove `credsStore` from `~/.docker/config.json` and let
  credentials fall back to the OS keychain.

---

## 11. Day-to-day commands

```bash
limactl list                   # show all instances and their status
limactl stop myvm              # stop the VM (frees RAM/CPU)
limactl start myvm             # start it again (re-runs provisioning)
limactl shell --workdir /workspaces myvm   # shell into the Ubuntu VM
limactl edit myvm              # change cpus/memory/mounts on an *existing* instance
limactl delete myvm            # nuke it and start over
~/Projects/azure-dev/lima-workflow/limavm-verify.sh myvm   # confirm provisioning actually succeeded
```

> ⚠️ **Editing `.limavm/ubuntu24-docker.yaml` after the instance already
> exists does nothing by itself.** Lima freezes the config into
> `~/.lima/myvm/lima.yaml` at `limactl create` time and doesn't re-read the
> source file on `limactl start`. To apply yaml changes (new mount, resized
> disk, tweaked provisioning) to an *existing* instance, use
> `limactl edit myvm` (which edits that frozen copy) — or just
> `limactl delete myvm` and recreate from the updated file (with the same
> `--set` as in [step 3](#3-create-the-lima-instance)). Changes to the
> `provision/*.sh` scripts themselves are the exception: since they're
> re-read from `/opt/lima-workflow` on every `limactl start`, editing those
> files on the Mac and running `limactl stop myvm && limactl start myvm` is
> enough — no recreate needed. The same goes for
> `.limavm/initialize_secrets.sh`. Script changes reach every project's VM
> at its next restart, because they all share this one copy.

---

## What gets installed automatically

On every `limactl start`, `provision/` runs in order (idempotent — safe to
re-run, each step checks what's already there):

| script | mode | installs |
|---|---|---|
| `00-system-packages.sh` | system (root) | git, vim, curl, jq, openssl, zsh, python3/pip/venv/pipx, `direnv`, GitHub CLI (`gh`), Azure CLI (`az`), Azure Developer CLI (`azd`), 1Password CLI (`op`) |
| `10-user-shell.sh` | user | oh-my-zsh, theme `edvardm`, plugins `git docker ssh-agent npm zsh-autosuggestions`, sets zsh as login shell |
| `20-user-tools.sh` | user | aws-cli (installed, unconfigured), tfenv + the latest Terraform, Bicep (`az bicep install`, also on PATH as `bicep`), nvm + Node LTS, Claude Code (`~/.local/bin/claude`), `pre-commit` (via pipx), direnv's zsh hook |
| `30-user-profile.sh` | user | git `https://github.com/` → SSH rewrite, runs `initialize_secrets.sh` if present, pre-seeds GitHub's SSH host key |

Version policy:

- **Terraform** moves to the newest release on every boot (`tfenv install
  latest`). If `releases.hashicorp.com` is unreachable, the boot keeps the
  already-installed version instead of failing. To pin a project to a specific
  version, drop a `.terraform-version` file in its repo; tfenv honours it.
- **Azure CLI** comes from Microsoft's apt repo, so `sudo apt-get upgrade`
  updates it. **Bicep** is installed once; update it with `az bicep upgrade`.
  **azd** prints a notice when a newer version exists; re-run its installer
  to update.
- **Claude Code** updates itself in the background, so the version isn't
  pinned by this repo.

### Optional helper tools

These are installed but do nothing until you use them:

| tool | what it is | how you'd use it here |
|---|---|---|
| `direnv` | Loads/unloads environment variables per directory: when you `cd` into a folder with an `.envrc`, its exports apply; when you leave, they're removed. | Per-repo settings such as `ARM_SUBSCRIPTION_ID` or `AZURE_LOCATION`, so switching repos switches context automatically. Each new or changed `.envrc` must be approved once with `direnv allow`. |
| `pre-commit` | A framework for git hooks: it runs the linters/formatters listed in a repo's `.pre-commit-config.yaml` on every `git commit` and blocks the commit if they fail. | e.g. `terraform fmt`/`tflint`, `bicep lint`, trailing-whitespace and secret scanners. Only the binary is installed; run `pre-commit install` in a repo to turn it on there. |
| `op` | 1Password CLI — reads secrets from a 1Password vault. | Not signed in (the desktop-app integration isn't available in a headless VM): `op account add`, then `eval "$(op signin)"`. Pairs with direnv to pull secrets into `.envrc` instead of writing them to disk. |

---

## Troubleshooting

### Monitoring the progress while the VM is booting
```bash
# Live, detailed view — our provision scripts run with set -x, so every command shows up here:
limactl shell --workdir /workspaces myvm -- sudo tail -f /var/log/cloud-init-output.log

# Just block until it's done, then check:
limactl shell --workdir /workspaces myvm -- cloud-init status --wait   # prints dots, then "status: done"

# The limavm-verify.sh script
~/Projects/azure-dev/lima-workflow/limavm-verify.sh myvm
```

Host-side view of Lima's own orchestration
```bash
# This is where a failing provision step reports
#   Failed to execute /mnt/lima-cidata/provision.user/…
tail -f ~/.lima/myvm/ha.stderr.log
```

### Other things

- **Provisioning times out waiting for the provision directory** — the
  first line of each provision step waits 30 s for
  `/opt/lima-workflow/provision`. If it never appears,
  `param.limaWorkflowDir` doesn't match where the repo actually is on the Mac
  (or the repo was moved after the VM was created). Check with
  `limactl list myvm --format '{{range .Config.Mounts}}{{.Location}} -> {{.MountPoint}}{{"\n"}}{{end}}'`,
  then fix it with `limactl edit myvm` or recreate the VM.
- **`no other shared folders` fails in `limavm-verify.sh`** — the VM was
  created without the `--set` from [step 3](#3-create-the-lima-instance), so
  your whole `$HOME` is mounted read-only. `limactl stop myvm`, then
  `limactl edit myvm` and delete the `- location: "~"` entry under `mounts:`.
- **`limactl create` downloaded Ubuntu 26.04 instead of 24.04** — see the
  `base:` order gotcha in [step 3](#3-create-the-lima-instance). Fix the
  order, `limactl delete myvm`, and recreate.
- **Mount not showing up in the guest** — re-check with `limactl shell myvm`
  then `mount | grep virtiofs`. If missing, `limactl edit myvm` and confirm
  both mounts are listed under `mounts:`: `/workspaces` with
  `writable: true`, `/opt/lima-workflow` with `writable: false`.
- **`az login` opens nothing / hangs** — use `--use-device-code`; the VM has
  no browser to redirect to.
- **`docker` commands hang or timeout** — make sure `lima-myvm` is actually
  the active context (`docker context ls`, look for the `*`) and that the VM
  is running (`limactl list`).
- **Wrong image architecture pulled** — check `docker version` output for
  `OS/Arch` under Server (should read `linux/arm64`); for amd64-only images,
  add `platform: linux/amd64` under the service in `docker-compose.yml` (or
  `--platform linux/amd64` on `docker run`).
- **amd64 container runs but feels slow** — you're likely getting plain QEMU
  emulation instead of Rosetta. Add `--device=lima-vm.io/rosetta=cached` to
  the `docker run` command, or confirm Rosetta is actually enabled with
  `limactl list myvm --format '{{.Config.VMOpts}}'`.
- **zsh theme/plugins never show up, or `node`/`terraform`/`bicep`/`claude`
  are missing from PATH** — most likely `~/.zshrc` inside the guest got out of
  sync with what `provision/10-user-shell.sh` / `20-user-tools.sh` expect
  (e.g. after a manual edit). `limactl stop myvm && limactl start myvm`
  re-runs provisioning, which repairs a half-installed oh-my-zsh, nvm or
  Claude Code on its own (each keys off the *file* it produces —
  `~/.oh-my-zsh/oh-my-zsh.sh`, `~/.nvm/nvm.sh`, `~/.local/bin/claude` —
  rather than the directory, so a partial tree doesn't block the retry). To
  force a fully clean re-install, `rm -rf ~/.oh-my-zsh ~/.nvm` inside the
  guest and restart; for Claude Code that's
  `rm -rf ~/.local/bin/claude ~/.local/share/claude`, which also throws away
  whatever version its background auto-updater had reached. Leave `~/.claude`
  and `~/.claude.json` alone unless you mean to log in again — that's where
  the login lives. Note that re-provisioning replaces `~/.zshrc` when
  oh-my-zsh is reinstalled, keeping a `~/.zshrc.pre-oh-my-zsh` backup.
- **Provisioning fails on a GitHub or vendor outage** — the provision scripts fetch
  oh-my-zsh, nvm and zsh-autosuggestions from `github.com` over `git clone`
  only, deliberately avoiding `raw.githubusercontent.com` (it fails
  independently — it returned HTTP 429 for hours during the 2026-08-17
  incident while git was healthy). Some things have no git-clone equivalent
  and are fetched over plain HTTPS instead: the Azure CLI and azd installers
  (`aka.ms`) and Claude Code (`claude.ai`), all piped straight into `bash`,
  plus the AWS CLI zip. Those use `curl -f` with retries, and the `-f` is the
  part that matters — without it curl exits 0 on an HTTP error and pipes the
  error *page* into `bash` as if it were the installer. Terraform
  (`releases.hashicorp.com`, via tfenv) and Bicep (GitHub releases, via
  `az bicep install`) are downloaded by their own tools. Everything except
  Terraform is only fetched on first install; Terraform falls back to the
  installed version if its lookup fails. If a fetch does fail, provisioning
  stops loudly with a
  `Failed to execute /mnt/lima-cidata/provision.user/...` warning; check
  `sudo less /var/log/cloud-init-output.log` in the guest, then just restart
  the VM once the upstream is healthy again.
- **`ssh -T git@github.com` fails with "Host key verification failed"** —
  `initialize_secrets.sh` writes the SSH key but GitHub's host key still
  needs trusting; `30-user-profile.sh` pre-seeds it automatically on boot,
  so this should only happen if you ran the secrets script manually outside
  of provisioning. Run `ssh-keyscan -t ed25519,rsa github.com >>
  ~/.ssh/known_hosts` inside the guest.
- **`git fetch`/`git pull` inside the VM asks for a GitHub username** — the
  repo's `origin` is an **https** URL. Git over https wants a
  username/password and never looks at your SSH key or `~/.ssh/config`; on the
  Mac it works because the `osxkeychain` credential helper holds a token, and
  the guest has no credential helper. `30-user-profile.sh` fixes this globally
  with `url."git@github.com:".insteadOf "https://github.com/"`, so if you're
  seeing the prompt, check `limavm-verify.sh`'s `git https->ssh rewrite` check
  and confirm `~/.gitconfig` exists in the guest. Don't "fix" it with
  `git remote set-url` — the repo's `.git` lives on the shared mount, so that
  would rewrite your Mac's remote too, and you'd have to repeat it per repo.
- **`git commit` inside the VM fails with "unable to auto-detect email
  address"** — no git identity in the guest. It's set by
  `initialize_secrets.sh`; if you created that file before this was added to
  the template, copy the `## Setup Git identity` block out of
  `initialize_secrets.sh.example` into it.
- **`github ssh authenticates ... WARN` in `limavm-verify.sh`** — your
  GitHub key has a passphrase and isn't unlocked yet. GitHub recognises the
  key, so provisioning did its part, but login can't be confirmed until the
  passphrase is entered, and the script can't type it for you. Open a VM shell
  (it asks for the passphrase) or run `ssh-add` there, then re-run the script.
  The verdict is `WARNING` until then.
- **Secrets/GitHub-SSH checks report `SKIP` in `limavm-verify.sh`** — expected
  if you haven't created `initialize_secrets.sh` yet (see
  [step 2](#2-create-the-projects-vm-config--secrets-files)); `SKIP` is not a failure
  and doesn't count towards the `WARNING`/`FAILED` verdict.
