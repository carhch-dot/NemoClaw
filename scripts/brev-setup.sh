#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Brev VM bootstrap — installs prerequisites then runs setup.sh.
#
# Run on a fresh Brev VM:
#   export NVIDIA_API_KEY=nvapi-...
#   export GITHUB_TOKEN=ghp_...    # needs read:packages scope
#   ./scripts/brev-setup.sh
#
# What it does:
#   1. Installs Docker (if missing)
#   2. Installs NVIDIA Container Toolkit (if GPU present)
#   3. Installs openshell CLI from GitHub release (binary, no Rust build)
#   4. Logs into ghcr.io for Docker image pulls
#   5. Runs setup.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[brev]${NC} $1"; }
warn() { echo -e "${YELLOW}[brev]${NC} $1"; }
fail() { echo -e "${RED}[brev]${NC} $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -n "${NVIDIA_API_KEY:-}" ] || fail "NVIDIA_API_KEY not set"

# Resolve GitHub token from env or gh CLI
GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$GITHUB_TOKEN" ] && command -v gh > /dev/null 2>&1; then
  GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
[ -n "$GITHUB_TOKEN" ] || fail "GITHUB_TOKEN not set and gh CLI not authenticated. Need a token with read:packages scope."

# --- 1. Docker ---
if ! command -v docker > /dev/null 2>&1; then
  info "Installing Docker..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker.io
  sudo usermod -aG docker "$(whoami)"
  info "Docker installed"
else
  info "Docker already installed"
fi

# --- 2. NVIDIA Container Toolkit (if GPU present) ---
if command -v nvidia-smi > /dev/null 2>&1; then
  if ! dpkg -s nvidia-container-toolkit > /dev/null 2>&1; then
    info "Installing NVIDIA Container Toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
    info "NVIDIA Container Toolkit installed"
  else
    info "NVIDIA Container Toolkit already installed"
  fi
fi

# --- 3. openshell CLI (binary release, not pip) ---
if ! command -v openshell > /dev/null 2>&1; then
  info "Installing openshell CLI from GitHub release..."
  if ! command -v gh > /dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq gh
  fi
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) ASSET="openshell-x86_64-unknown-linux-musl.tar.gz" ;;
    aarch64|arm64) ASSET="openshell-aarch64-unknown-linux-musl.tar.gz" ;;
    *) fail "Unsupported architecture: $ARCH" ;;
  esac
  tmpdir="$(mktemp -d)"
  GH_TOKEN="$GITHUB_TOKEN" gh release download --repo NVIDIA/OpenShell \
    --pattern "$ASSET" --dir "$tmpdir"
  tar xzf "$tmpdir/$ASSET" -C "$tmpdir"
  sudo install -m 755 "$tmpdir/openshell" /usr/local/bin/openshell
  rm -rf "$tmpdir"
  info "openshell $(openshell --version) installed"
else
  info "openshell already installed: $(openshell --version)"
fi

# --- 4. GHCR Docker login ---
info "Logging into ghcr.io..."
GHCR_USER="$(GH_TOKEN="$GITHUB_TOKEN" gh api user -q .login 2>/dev/null || echo "${USER:-ubuntu}")"
echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin 2>/dev/null
echo "$GITHUB_TOKEN" | sudo docker login ghcr.io -u "$GHCR_USER" --password-stdin 2>/dev/null
info "GHCR login done"

# --- 5. Run setup.sh ---
info "Running setup.sh..."
export NVIDIA_API_KEY
export GITHUB_TOKEN
exec bash "$SCRIPT_DIR/setup.sh"
