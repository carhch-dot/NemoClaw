# NemoClaw — OpenClaw Plugin for OpenShell

Run OpenClaw inside an OpenShell sandbox with NVIDIA inference (Nemotron 3 Super 120B via [build.nvidia.com](https://build.nvidia.com), or local Ollama).

## Installation

### Requirements

All platforms need:

- `NVIDIA_API_KEY` — get one from [build.nvidia.com](https://build.nvidia.com)
- A GitHub token with `read:packages` scope (for pulling OpenShell container images)

### macOS (Colima or Docker Desktop)

```bash
# Install dependencies
brew install colima docker gh
pip install 'openshell @ git+https://github.com/NVIDIA/OpenShell.git'

# Start Docker runtime
colima start        # or use Docker Desktop

# Clone and run
git clone https://github.com/NVIDIA/openshell-openclaw-plugin.git
cd openshell-openclaw-plugin
export NVIDIA_API_KEY=nvapi-...
./scripts/setup.sh
```

### Linux (native Docker)

```bash
# Install dependencies
sudo apt-get install -y docker.io
pip install 'openshell @ git+https://github.com/NVIDIA/OpenShell.git'

# If you have an NVIDIA GPU, install the container toolkit:
# https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html

# Clone and run
git clone https://github.com/NVIDIA/openshell-openclaw-plugin.git
cd openshell-openclaw-plugin
export NVIDIA_API_KEY=nvapi-...
./scripts/setup.sh
```

### Brev

For Brev VMs, a bootstrap script handles all prerequisite installation (Docker, NVIDIA Container Toolkit, openshell CLI binary, GHCR auth):

```bash
# Create a Brev instance (GPU optional — inference is cloud-hosted)
brev create nemoclaw --gpu "a2-highgpu-1g:nvidia-tesla-a100:1"
brev shell nemoclaw

# On the Brev VM:
git clone https://github.com/NVIDIA/openshell-openclaw-plugin.git
cd openshell-openclaw-plugin
export NVIDIA_API_KEY=nvapi-...
export GITHUB_TOKEN=ghp_...    # needs read:packages scope
./scripts/brev-setup.sh
```

`brev-setup.sh` installs Docker, the NVIDIA Container Toolkit (if GPU present), the `openshell` CLI from a pre-built binary, authenticates with `ghcr.io`, then runs `setup.sh` automatically.

### Other cloud VMs (EC2, GCE, Azure)

Any Ubuntu 22.04+ VM with Docker works. The Brev bootstrap script is a good reference — the same steps apply:

1. Install Docker and (optionally) the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
2. Install the `openshell` CLI — either `pip install 'openshell @ git+https://github.com/NVIDIA/OpenShell.git'` or download the binary from [GitHub releases](https://github.com/NVIDIA/OpenShell/releases)
3. Authenticate Docker with `ghcr.io` (`docker login ghcr.io`)
4. Clone this repo and run `./scripts/setup.sh`

## Usage

### Connect to the sandbox

```bash
openshell sandbox connect nemoclaw
export NVIDIA_API_KEY=nvapi-...
nemoclaw-start
```

### Run OpenClaw

```bash
openclaw agent --agent main --local -m "your prompt" --session-id s1
```

### Switch inference providers

```bash
# NVIDIA cloud (Nemotron 3 Super 120B)
openshell inference set --provider nvidia-nim --model nvidia/nemotron-3-super-120b-a12b

# Local Ollama (Nemotron Mini)
openshell inference set --provider ollama-local --model nemotron-mini
```

### Monitor

```bash
openshell term
```

## Architecture

```
nemoclaw/                           Thin TypeScript plugin (in-process with OpenClaw gateway)
├── src/
│   ├── index.ts                    Plugin entry — registers all nemoclaw commands
│   ├── commands/
│   │   ├── launch.ts               Fresh install (prefers OpenShell-native for net-new)
│   │   ├── migrate.ts              Migrate host OpenClaw into sandbox
│   │   ├── connect.ts              Interactive shell into sandbox
│   │   ├── status.ts               Blueprint run state + sandbox health
│   │   └── eject.ts                Rollback to host install from snapshot
│   └── blueprint/
│       ├── resolve.ts              Version resolution, cache management
│       ├── verify.ts               Digest verification, compatibility checks
│       ├── exec.ts                 Subprocess execution of blueprint runner
│       └── state.ts                Persistent state (run IDs, snapshots)
├── openclaw.plugin.json            Plugin manifest
└── package.json                    Commands declared under openclaw.extensions

nemoclaw-blueprint/                 Versioned blueprint artifact (separate release stream)
├── blueprint.yaml                  Manifest — version, profiles, compatibility
├── orchestrator/
│   └── runner.py                   CLI runner — plan / apply / status / rollback
├── policies/
│   └── openclaw-sandbox.yaml       Strict baseline network + filesystem policy
├── migrations/
│   └── snapshot.py                 Snapshot / restore / cutover / rollback logic
└── iac/                            (future) Declarative infrastructure modules
```

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/setup.sh` | Host-side setup — gateway, providers, inference route, sandbox |
| `scripts/brev-setup.sh` | Brev bootstrap — installs prerequisites, then runs `setup.sh` |
| `scripts/nemoclaw-start.sh` | Sandbox entrypoint — configures OpenClaw, installs plugin |
| `scripts/fix-coredns.sh` | CoreDNS patch for Colima environments |

## Commands

| Command | Description |
|---------|-------------|
| `openclaw nemoclaw launch` | Fresh install into OpenShell (warns net-new users) |
| `openclaw nemoclaw migrate` | Migrate host OpenClaw into sandbox (snapshot + cutover) |
| `openclaw nemoclaw connect` | Interactive shell into the sandbox |
| `openclaw nemoclaw status` | Blueprint state, sandbox health, inference config |
| `openclaw nemoclaw eject` | Rollback to host installation from snapshot |
| `/nemoclaw` | Slash command in chat (status, eject) |

## Inference Profiles

| Profile | Provider | Model | Use Case |
|---------|----------|-------|----------|
| `default` | NVIDIA cloud | nemotron-3-super-120b-a12b | Production, requires API key |
| `nim-local` | Local NIM service | nemotron-3-super-120b-a12b | On-prem, NIM deployed as pod |
| `ollama` | Ollama | llama3.1:8b | Local development, no API key |

## Design Principles

1. **Thin plugin, versioned blueprint** — Plugin stays small and stable; orchestration logic evolves independently
2. **Respect CLI boundaries** — Plugin commands live under `nemoclaw` namespace, never override built-in OpenClaw commands
3. **Supply chain safety** — Immutable versioned artifacts with digest verification
4. **OpenShell-native for net-new** — Don't force double-install; prefer `openshell sandbox create`
5. **Snapshot everything** — Every migration creates a restorable backup
