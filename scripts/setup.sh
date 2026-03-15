#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# NemoClaw setup — run this on the HOST to set up everything.
#
# Prerequisites:
#   - Docker running (Colima, Docker Desktop, or native)
#   - openshell CLI installed (pip install openshell @ git+https://github.com/NVIDIA/OpenShell.git)
#   - gh CLI authenticated with read:packages scope
#   - NVIDIA_API_KEY set in environment (from build.nvidia.com)
#
# Usage:
#   export NVIDIA_API_KEY=nvapi-...
#   ./scripts/setup.sh
#
# What it does:
#   1. Starts an OpenShell gateway (or reuses existing)
#   2. Fixes CoreDNS for Colima environments
#   3. Creates nvidia-nim provider (build.nvidia.com)
#   4. Creates ollama-local provider (if Ollama is running)
#   5. Sets inference route to nvidia-nim by default
#   6. Builds and creates the NemoClaw sandbox
#   7. Prints next steps

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}>>>${NC} $1"; }
warn() { echo -e "${YELLOW}>>>${NC} $1"; }
fail() { echo -e "${RED}>>>${NC} $1"; exit 1; }

# Resolve DOCKER_HOST for Colima if needed
if [ -z "${DOCKER_HOST:-}" ]; then
  if [ -S "$HOME/.colima/default/docker.sock" ]; then
    export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
    warn "Using Colima Docker socket"
  fi
fi

# Check prerequisites
command -v openshell > /dev/null || fail "openshell CLI not found. Install: pip install 'openshell @ git+https://github.com/NVIDIA/OpenShell.git'"
command -v docker > /dev/null || fail "docker not found"
[ -n "${NVIDIA_API_KEY:-}" ] || fail "NVIDIA_API_KEY not set. Get one from build.nvidia.com"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 1. Gateway
info "Checking OpenShell gateway..."
if openshell status 2>&1 | grep -q "Connected"; then
  info "Gateway already running"
else
  info "Starting OpenShell gateway..."
  REGISTRY_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-$(gh auth token 2>/dev/null || echo "")}}"
  GATEWAY_ARGS=(--name nemoclaw)
  [ -n "$REGISTRY_TOKEN" ] && GATEWAY_ARGS+=(--registry-token "$REGISTRY_TOKEN")
  command -v nvidia-smi > /dev/null 2>&1 && GATEWAY_ARGS+=(--gpu)
  openshell gateway start "${GATEWAY_ARGS[@]}" 2>&1 | tail -5
fi

# 2. CoreDNS fix (Colima only)
if [ -S "$HOME/.colima/default/docker.sock" ]; then
  info "Patching CoreDNS for Colima..."
  bash "$SCRIPT_DIR/fix-coredns.sh" 2>&1 || warn "CoreDNS patch failed (may not be needed)"
fi

# 3. Providers
info "Setting up inference providers..."

# nvidia-nim (build.nvidia.com)
if openshell provider create --name nvidia-nim --type openai \
  --credential "NVIDIA_API_KEY=$NVIDIA_API_KEY" \
  --config "OPENAI_BASE_URL=https://integrate.api.nvidia.com/v1" 2>&1 | grep -q "AlreadyExists"; then
  info "nvidia-nim provider already exists"
else
  info "Created nvidia-nim provider"
fi

# ollama-local (if running)
if curl -s http://localhost:11434/v1/models > /dev/null 2>&1; then
  if openshell provider create --name ollama-local --type openai \
    --credential "OPENAI_API_KEY=dummy" \
    --config "OPENAI_BASE_URL=http://host.docker.internal:11434/v1" 2>&1 | grep -q "AlreadyExists"; then
    info "ollama-local provider already exists"
  else
    info "Created ollama-local provider (Ollama detected on localhost:11434)"
  fi
fi

# 4. Inference route — default to nvidia-nim
info "Setting inference route to nvidia-nim / Nemotron 3 Super..."
openshell inference set --provider nvidia-nim --model nvidia/nemotron-3-super-120b-a12b > /dev/null 2>&1

# 5. Build and create sandbox
info "Deleting old nemoclaw sandbox (if any)..."
openshell sandbox delete nemoclaw > /dev/null 2>&1 || true

info "Building and creating NemoClaw sandbox (this takes a few minutes on first run)..."
openshell sandbox create --from "$REPO_DIR/Dockerfile" --name nemoclaw

# 6. Done
echo ""
info "Setup complete!"
echo ""
echo "  Connect to the sandbox:"
echo "    openshell sandbox connect nemoclaw"
echo ""
echo "  Then run the setup script inside:"
echo "    export NVIDIA_API_KEY=$NVIDIA_API_KEY"
echo "    nemoclaw-start"
echo ""
echo "  Then use OpenClaw:"
echo "    openclaw agent --agent main --local -m 'your prompt' --session-id s1"
echo ""
echo "  Test inference.local routing:"
echo "    bash /tmp/test-inference.sh"
echo ""
echo "  Switch to local Ollama:"
echo "    openshell inference set --provider ollama-local --model nemotron-mini"
echo ""
echo "  Monitor in TUI:"
echo "    openshell term"
