#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# NemoClaw sandbox entrypoint. Runs as root (via ENTRYPOINT) to start the
# gateway as the 'gateway' user, then drops to 'sandbox' for agent commands.
#
# SECURITY: The gateway runs as a separate user so the sandboxed agent cannot
# kill it or restart it with a tampered config (CVE: fake-HOME bypass).
# The config hash is verified at startup to detect tampering.
#
# Optional env:
#   NVIDIA_API_KEY                API key for NVIDIA-hosted inference
#   CHAT_UI_URL                   Browser origin that will access the forwarded dashboard
#   NEMOCLAW_DISABLE_DEVICE_AUTH  Build-time only. Set to "1" to skip device-pairing auth
#                                 (development/headless). Has no runtime effect — openclaw.json
#                                 is baked at image build and verified by hash at startup.

set -euo pipefail

# ── Ensure we are running as root ─────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: NemoClaw must be started as root (to handle user isolation/volumes)." >&2
  exit 1
fi

# Harden: limit process count to prevent fork bombs (ref: #809)
# Best-effort: some container runtimes (e.g., brev) restrict ulimit
# modification, returning "Invalid argument". Warn but don't block startup.
if ! ulimit -Su 512 2>/dev/null; then
  echo "[SECURITY] Could not set soft nproc limit (container runtime may restrict ulimit)" >&2
fi
if ! ulimit -Hu 512 2>/dev/null; then
  echo "[SECURITY] Could not set hard nproc limit (container runtime may restrict ulimit)" >&2
fi

# SECURITY: Lock down PATH so the agent cannot inject malicious binaries
# into commands executed by the entrypoint or auto-pair watcher.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ── Privileged setup: Volumes and Users ──────────────────────────
# Perform all operations that require CAP_DAC_OVERRIDE/privileged access
# BEFORE dropping capabilities or re-execing via capsh.
if [ "${NEMOCLAW_CAPS_DROPPED:-}" != "1" ]; then
  echo "--- DEEP DIAGNOSTICS START ---" >&2
  echo "UID: $(id -u), GID: $(id -g), GROUPS: $(id -G)" >&2
  echo "CAPS: $(command -v capsh >/dev/null 2>&1 && capsh --print | grep Current || echo 'capsh not found')" >&2
  echo "MOUNT: $(mount | grep /sandbox || echo '/sandbox not found in mount')" >&2
  echo "LS -LD /sandbox: $(ls -ld /sandbox 2>&1)" >&2
  echo "LS -LD /sandbox/.openclaw-data: $(ls -ld /sandbox/.openclaw-data 2>&1)" >&2
  if command -v lsattr >/dev/null 2>&1; then
    echo "LSATTR /sandbox: $(lsattr -d /sandbox 2>&1)" >&2
    echo "LSATTR /sandbox/.openclaw-data: $(lsattr -d /sandbox/.openclaw-data 2>&1)" >&2
  fi
  echo "--- DEEP DIAGNOSTICS END ---" >&2

  echo "Setting up NemoClaw (privileged setup)..." >&2
  
  # FORCE REMEDIATION: Force remount RW if somehow RO
  mount -o remount,rw /sandbox 2>/dev/null || true
  mount -o remount,rw /sandbox/.openclaw-data 2>/dev/null || true

  # FORCE REMEDIATION: Clear immutable/append-only bits if present
  if command -v chattr >/dev/null 2>&1; then
    chattr -i -a /sandbox /sandbox/.openclaw-data /sandbox/.openclaw /sandbox/.openclaw-data/* 2>/dev/null || true
  fi

  # Ensure state directories exist on volume
  # Using explicit error check for mkdir
  if ! mkdir -p /sandbox/.openclaw-data/logs /sandbox/.openclaw-data/cron /sandbox/.openclaw-data/devices; then
    echo "CRITICAL ERROR: mkdir failed even as root. Checking for file collision..." >&2
    [ -f /sandbox/.openclaw-data ] && echo "ERROR: /sandbox/.openclaw-data is a FILE, not a directory!" >&2
    [ -f /sandbox/.openclaw-data/logs ] && echo "ERROR: /sandbox/.openclaw-data/logs is a FILE, not a directory!" >&2
    exit 1
  fi
  
  touch /sandbox/.openclaw-data/gateway.pid
  
  # Shared group membership
  usermod -aG gateway sandbox || true
  usermod -aG sandbox gateway || true
  
  # Ensure correct ownership of the writable state
  chown -R gateway:gateway /sandbox/.openclaw-data
  chmod -R 775 /sandbox/.openclaw-data

  # Setup symlinks in .openclaw (which is owned by root)
  ln -sf /sandbox/.openclaw-data/gateway.pid /sandbox/.openclaw/gateway.pid
  ln -sf /sandbox/.openclaw-data/logs /sandbox/.openclaw/logs
  ln -sf /sandbox/.openclaw-data/devices /sandbox/.openclaw/devices
fi

# ── Drop unnecessary Linux capabilities ──────────────────────────
# CIS Docker Benchmark 5.3: containers should not run with default caps.
# Kept: cap_chown, cap_setuid, cap_setgid, cap_fowner, cap_kill
#   — required by the entrypoint for gosu privilege separation and chown.
if [ "${NEMOCLAW_CAPS_DROPPED:-}" != "1" ] && command -v capsh >/dev/null 2>&1; then
  if capsh --has-p=cap_setpcap 2>/dev/null; then
    export NEMOCLAW_CAPS_DROPPED=1
    exec capsh \
      --drop=cap_net_raw,cap_dac_override,cap_sys_chroot,cap_fsetid,cap_setfcap,cap_mknod,cap_audit_write,cap_net_bind_service \
      -- -c 'exec /usr/local/bin/nemoclaw-start "$@"' -- "$@"
  else
    echo "[SECURITY] CAP_SETPCAP not available — runtime already restricts capabilities" >&2
  fi
elif [ "${NEMOCLAW_CAPS_DROPPED:-}" != "1" ]; then
  echo "[SECURITY WARNING] capsh not available — running with default capabilities" >&2
fi


# Normalize the sandbox-create bootstrap wrapper. Onboard launches the
# container as `env CHAT_UI_URL=... nemoclaw-start`, but this script is already
# the ENTRYPOINT. If we treat that wrapper as a real command, the root path will
# try `gosu sandbox env ... nemoclaw-start`, which fails on Spark/arm64 when
# no-new-privileges blocks gosu. Consume only the self-wrapper form and promote
# the env assignments into the current process.
if [ "${1:-}" = "env" ]; then
  _raw_args=("$@")
  _self_wrapper_index=""
  for ((i = 1; i < ${#_raw_args[@]}; i += 1)); do
    case "${_raw_args[$i]}" in
      *=*) ;;
      nemoclaw-start | /usr/local/bin/nemoclaw-start)
        _self_wrapper_index="$i"
        break
        ;;
      *)
        break
        ;;
    esac
  done
  if [ -n "$_self_wrapper_index" ]; then
    for ((i = 1; i < _self_wrapper_index; i += 1)); do
      export "${_raw_args[$i]}"
    done
    set -- "${_raw_args[@]:$((_self_wrapper_index + 1))}"
  fi
fi

# Filter out direct self-invocation too. Since this script is the ENTRYPOINT,
# receiving our own name as $1 would otherwise recurse via the NEMOCLAW_CMD
# exec path. Only strip from $1 — later args with this name are legitimate.
case "${1:-}" in
  nemoclaw-start | /usr/local/bin/nemoclaw-start) shift ;;
esac
NEMOCLAW_CMD=("$@")
CHAT_UI_URL="${CHAT_UI_URL:-http://127.0.0.1:18789}"
PUBLIC_PORT=18789
OPENCLAW="$(command -v openclaw)" # Resolve once, use absolute path everywhere

# ── Config integrity check ──────────────────────────────────────
# The config hash was pinned at build time. If it doesn't match,
# someone (or something) has tampered with the config.

verify_config_integrity() {
  local hash_file="/sandbox/.openclaw/.config-hash"
  if [ ! -f "$hash_file" ]; then
    echo "[SECURITY] Config hash file missing — refusing to start without integrity verification" >&2
    return 1
  fi
  if ! (cd /sandbox/.openclaw && sha256sum -c "$hash_file" --status 2>/dev/null); then
    echo "[SECURITY] openclaw.json integrity check FAILED — config may have been tampered with" >&2
    echo "[SECURITY] Expected hash: $(cat "$hash_file")" >&2
    echo "[SECURITY] Actual hash:   $(sha256sum /sandbox/.openclaw/openclaw.json)" >&2
    return 1
  fi
}

patch_runtime_config() {
  if [ -z "${CHAT_UI_URL:-}" ] && [ -z "${NEMOCLAW_DISABLE_DEVICE_AUTH:-}" ]; then
    return
  fi

  # Temporarily drop immutable flag to allow patching
  if [ "$(id -u)" -eq 0 ] && command -v chattr >/dev/null 2>&1; then
    chattr -i /sandbox/.openclaw /sandbox/.openclaw/openclaw.json /sandbox/.openclaw/.config-hash 2>/dev/null || true
  fi

  python3 - <<'PYCONFIG'
import json, os, hashlib
from urllib.parse import urlparse

url = os.environ.get('CHAT_UI_URL', '')
disable_device_auth = os.environ.get('NEMOCLAW_DISABLE_DEVICE_AUTH', '') == '1'

path = '/sandbox/.openclaw/openclaw.json'
hash_file = '/sandbox/.openclaw/.config-hash'

try:
    with open(path, 'r') as f:
        config = json.load(f)
except Exception:
    exit(0)

modified = False
url = os.environ.get('CHAT_UI_URL', '')
disable_device_auth = os.environ.get('NEMOCLAW_DISABLE_DEVICE_AUTH', '') == '1'
gateway_token = os.environ.get('NEMOCLAW_GATEWAY_TOKEN', '')

# 1. Patch Allowed Origins
if url:
    parsed = urlparse(url)
    origin = f'{parsed.scheme}://{parsed.netloc}' if parsed.scheme and parsed.netloc else 'http://127.0.0.1:18789'
    origins = config.get('gateway', {}).get('controlUi', {}).get('allowedOrigins', [])
    if origin not in origins:
        print(f'[gateway] dynamic-config: adding origin {origin}')
        origins.append(origin)
        config.setdefault('gateway', {}).setdefault('controlUi', {})['allowedOrigins'] = list(dict.fromkeys(origins))
        modified = True

# 2. Patch Device Auth
if disable_device_auth:
    current = config.get('gateway', {}).get('controlUi', {}).get('dangerouslyDisableDeviceAuth', False)
    if not current:
        print(f'[gateway] dynamic-config: disabling device auth (headless mode)')
        config.setdefault('gateway', {}).setdefault('controlUi', {})['dangerouslyDisableDeviceAuth'] = True
        modified = True

# 3. Patch Gateway Token
if gateway_token:
    current = config.get('gateway', {}).get('auth', {}).get('token', '')
    if gateway_token != current:
        print(f'[gateway] dynamic-config: updating gateway auth token')
        config.setdefault('gateway', {}).setdefault('auth', {})['token'] = gateway_token
        modified = True

# 4. Patch Trusted Proxies
trusted = ['127.0.0.1', '::1', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']
current_trusted = config.get('gateway', {}).get('trustedProxies', [])
if any(t not in current_trusted for t in trusted):
    print(f'[gateway] dynamic-config: updating trusted proxies')
    config.setdefault('gateway', {})['trustedProxies'] = list(dict.fromkeys(current_trusted + trusted))
    modified = True

if modified:
    try:
        os.chmod(path, 0o600)
        with open(path, 'w') as f:
            json.dump(config, f, indent=2)
        os.chmod(path, 0o444)
        
        # Recalculate hash
        with open(path, 'rb') as f:
            new_hash = hashlib.sha256(f.read()).hexdigest()
        with open(hash_file, 'w') as f:
            f.write(f'{new_hash}  /sandbox/.openclaw/openclaw.json\n')
        os.chmod(hash_file, 0o444)
    except Exception as e:
        print(f'[gateway] dynamic-config error: {e}')
PYCONFIG
}

write_auth_profile() {
  if [ -z "${NVIDIA_API_KEY:-}" ]; then
    return
  fi

  python3 - <<'PYAUTH'
import json
import os
path = os.path.expanduser('~/.openclaw/agents/main/agent/auth-profiles.json')
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({
    'nvidia:manual': {
        'type': 'api_key',
        'provider': 'nvidia',
        'keyRef': {'source': 'env', 'id': 'NVIDIA_API_KEY'},
        'profileId': 'nvidia:manual',
    }
}, open(path, 'w'))
os.chmod(path, 0o600)
PYAUTH
}

print_dashboard_urls() {
  local token chat_ui_base local_url remote_url

  token="$(
    python3 - <<'PYTOKEN'
import json
import os
path = '/sandbox/.openclaw/openclaw.json'
try:
    cfg = json.load(open(path))
except Exception:
    print('')
else:
    print(cfg.get('gateway', {}).get('auth', {}).get('token', ''))
PYTOKEN
  )"

  chat_ui_base="${CHAT_UI_URL%/}"
  local_url="http://127.0.0.1:${PUBLIC_PORT}/"
  remote_url="${chat_ui_base}/"
  if [ -n "$token" ]; then
    local_url="${local_url}#token=${token}"
    remote_url="${remote_url}#token=${token}"
  fi

  echo "[gateway] Local UI: ${local_url}" >&2
  echo "[gateway] Remote UI: ${remote_url}" >&2
}

start_auto_pair() {
  # Run auto-pair as sandbox user (it talks to the gateway via CLI)
  # SECURITY: Pass resolved openclaw path to prevent PATH hijacking
  # When running as non-root, skip gosu (we're already the sandbox user)
  local run_prefix=()
  if [ "$(id -u)" -eq 0 ]; then
    run_prefix=(gosu gateway bash -c "exec python3 - >>/tmp/auto-pair.log 2>&1")
  else
    run_prefix=(bash -c "exec python3 - >>/tmp/auto-pair.log 2>&1")
  fi
  OPENCLAW_BIN="$OPENCLAW" nohup "${run_prefix[@]}" >/dev/null 2>&1 <<'PYAUTOPAIR' &
import json
import os
import subprocess
import time

OPENCLAW = os.environ.get('OPENCLAW_BIN', 'openclaw')
DEADLINE = time.time() + 600
QUIET_POLLS = 0
APPROVED = 0
HANDLED = set()  # Track rejected/approved requestIds to avoid reprocessing
# SECURITY NOTE: clientId/clientMode are client-supplied and spoofable
# (the gateway stores connectParams.client.id verbatim). This allowlist
# is defense-in-depth, not a trust boundary. PR #690 adds one-shot exit,
# timeout reduction, and token cleanup for a more comprehensive fix.
ALLOWED_CLIENTS = {'openclaw-control-ui'}
ALLOWED_MODES = {'webchat'}

def run(*args):
    proc = subprocess.run(args, capture_output=True, text=True)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()

while time.time() < DEADLINE:
    rc, out, err = run(OPENCLAW, 'devices', 'list', '--json')
    if rc != 0 or not out:
        time.sleep(1)
        continue
    try:
        data = json.loads(out)
    except Exception:
        time.sleep(1)
        continue

    pending = data.get('pending') or []
    paired = data.get('paired') or []
    has_browser = any((d.get('clientId') == 'openclaw-control-ui') or (d.get('clientMode') == 'webchat') for d in paired if isinstance(d, dict))

    if pending:
        QUIET_POLLS = 0
        for device in pending:
            if not isinstance(device, dict):
                continue
            request_id = device.get('requestId')
            if not request_id or request_id in HANDLED:
                continue
            client_id = device.get('clientId', '')
            client_mode = device.get('clientMode', '')
            if client_id not in ALLOWED_CLIENTS and client_mode not in ALLOWED_MODES:
                HANDLED.add(request_id)
                print(f'[auto-pair] rejected unknown client={client_id} mode={client_mode}')
                continue
            arc, aout, aerr = run(OPENCLAW, 'devices', 'approve', request_id, '--json')
            HANDLED.add(request_id)
            if arc == 0:
                APPROVED += 1
                print(f'[auto-pair] approved request={request_id} client={client_id}')
            elif aout or aerr:
                print(f'[auto-pair] approve failed request={request_id}: {(aerr or aout)[:400]}')
        time.sleep(1)
        continue

    if has_browser:
        QUIET_POLLS += 1
        if QUIET_POLLS >= 4:
            print(f'[auto-pair] browser pairing converged approvals={APPROVED}')
            break
    elif APPROVED > 0:
        QUIET_POLLS += 1
    else:
        QUIET_POLLS = 0

    time.sleep(1)
else:
    print(f'[auto-pair] watcher timed out approvals={APPROVED}')
PYAUTOPAIR
  echo "[gateway] auto-pair watcher launched (pid $!)" >&2
}

start_telegram_bridge() {
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
    echo "[services] Telegram bridge skipped: TELEGRAM_BOT_TOKEN not set" >&2
    return
  fi

  echo 'Starting Telegram bridge...' >&2
  touch /tmp/telegram-bridge.log
  chmod 666 /tmp/telegram-bridge.log

  # Local mode for bridge
  export TELEGRAM_BRIDGE_LOCAL=1
  
  if [ "$(id -u)" -eq 0 ]; then
    # Root mode: run as sandbox user
    nohup gosu sandbox bash -c "exec node /opt/nemoclaw/scripts/telegram-bridge.cjs" >>/tmp/telegram-bridge.log 2>&1 &
  else
    # Non-root mode: run as current user
    nohup node /opt/nemoclaw/scripts/telegram-bridge.cjs >>/tmp/telegram-bridge.log 2>&1 &
  fi
  echo "[services] Telegram bridge started (pid $!)" >&2
}

# ── Proxy environment ────────────────────────────────────────────
# OpenShell injects HTTP_PROXY/HTTPS_PROXY/NO_PROXY into the sandbox, but its
# NO_PROXY is limited to 127.0.0.1,localhost,::1 — missing the gateway IP.
# The gateway IP itself must bypass the proxy to avoid proxy loops.
#
# Do NOT add inference.local here. OpenShell intentionally routes that hostname
# through the proxy path; bypassing the proxy forces a direct DNS lookup inside
# the sandbox, which breaks inference.local resolution.
#
# NEMOCLAW_PROXY_HOST / NEMOCLAW_PROXY_PORT can be overridden at sandbox
# creation time if the gateway IP or port changes in a future OpenShell release.
# Ref: https://github.com/NVIDIA/NemoClaw/issues/626
PROXY_HOST="${NEMOCLAW_PROXY_HOST:-10.200.0.1}"
PROXY_PORT="${NEMOCLAW_PROXY_PORT:-3128}"
_PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"
_NO_PROXY_VAL="localhost,127.0.0.1,::1,${PROXY_HOST}"
export HTTP_PROXY="$_PROXY_URL"
export HTTPS_PROXY="$_PROXY_URL"
export NO_PROXY="$_NO_PROXY_VAL"
export http_proxy="$_PROXY_URL"
export https_proxy="$_PROXY_URL"
export no_proxy="$_NO_PROXY_VAL"

# OpenShell re-injects narrow NO_PROXY/no_proxy=127.0.0.1,localhost,::1 every
# time a user connects via `openshell sandbox connect`.  The connect path spawns
# `/bin/bash -i` (interactive, non-login), which sources ~/.bashrc — NOT
# ~/.profile or /etc/profile.d/*.  Write the full proxy config to ~/.bashrc so
# interactive sessions see the correct values.
#
# Both uppercase and lowercase variants are required: Node.js undici prefers
# lowercase (no_proxy) over uppercase (NO_PROXY) when both are set.
# curl/wget use uppercase.  gRPC C-core uses lowercase.
#
# Also write to ~/.profile for login-shell paths (e.g. `sandbox create -- cmd`
# which spawns `bash -lc`).
#
# Idempotency: begin/end markers delimit the block so it can be replaced
# on restart if NEMOCLAW_PROXY_HOST/PORT change, without duplicating.
_PROXY_MARKER_BEGIN="# nemoclaw-proxy-config begin"
_PROXY_MARKER_END="# nemoclaw-proxy-config end"
_PROXY_SNIPPET="${_PROXY_MARKER_BEGIN}
export HTTP_PROXY=\"$_PROXY_URL\"
export HTTPS_PROXY=\"$_PROXY_URL\"
export NO_PROXY=\"$_NO_PROXY_VAL\"
export http_proxy=\"$_PROXY_URL\"
export https_proxy=\"$_PROXY_URL\"
export no_proxy=\"$_NO_PROXY_VAL\"
${_PROXY_MARKER_END}"

if [ "$(id -u)" -eq 0 ]; then
  _SANDBOX_HOME=$(getent passwd sandbox 2>/dev/null | cut -d: -f6)
  _SANDBOX_HOME="${_SANDBOX_HOME:-/sandbox}"
else
  _SANDBOX_HOME="${HOME:-/sandbox}"
fi

_write_proxy_snippet() {
  local target="$1"
  if [ -f "$target" ] && grep -qF "$_PROXY_MARKER_BEGIN" "$target" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    awk -v b="$_PROXY_MARKER_BEGIN" -v e="$_PROXY_MARKER_END" \
      '$0==b{s=1;next} $0==e{s=0;next} !s' "$target" >"$tmp"
    printf '%s\n' "$_PROXY_SNIPPET" >>"$tmp"
    cat "$tmp" >"$target"
    rm -f "$tmp"
    return 0
  fi
  printf '\n%s\n' "$_PROXY_SNIPPET" >>"$target"
}

if [ -w "$_SANDBOX_HOME" ]; then
  _write_proxy_snippet "${_SANDBOX_HOME}/.bashrc"
  _write_proxy_snippet "${_SANDBOX_HOME}/.profile"
fi

echo 'Setting up NemoClaw (v15)...' >&2

# Forcibly unlock .openclaw immediately to avoid any Permission denied errors
if command -v chattr >/dev/null 2>&1; then
  chattr -i /sandbox/.openclaw 2>/dev/null || true
  chattr -i /sandbox/.openclaw/openclaw.json 2>/dev/null || true
  chattr -i /sandbox/.openclaw/devices 2>/dev/null || true
fi

# ── Runtime preparation ──────────────────────────────────────────
verify_config_integrity || exit 1
patch_runtime_config

# Proactively fix .openclaw permissions/symlinks for gateway user (UID 1001)
# Specifically the 'devices' directory which needs to be writable for pairing.
if [ "$(id -u)" -eq 0 ]; then
  mkdir -p /sandbox/.openclaw-data/devices
  # If it's a real directory (created by build), move content to volume.
  if [ -d /sandbox/.openclaw/devices ] && [ ! -L /sandbox/.openclaw/devices ]; then
    cp -rp /sandbox/.openclaw/devices/* /sandbox/.openclaw-data/devices/ 2>/dev/null || true
  fi
  # Forcibly remove existing link or file to avoid nesting 'devices/devices'
  rm -rf /sandbox/.openclaw/devices
  ln -sf /sandbox/.openclaw-data/devices /sandbox/.openclaw/devices
  
  # Ensure the gateway and sandbox users can both read/write to the shared state.
  mkdir -p /sandbox/.openclaw-data/logs /sandbox/.openclaw-data/cron
  touch /sandbox/.openclaw-data/gateway.pid
  
  # Bidirectional group membership for shared access
  usermod -aG gateway sandbox || true
  usermod -aG sandbox gateway || true
  
  chown -R gateway:gateway /sandbox/.openclaw-data
  chmod -R 775 /sandbox/.openclaw-data

  # Redirect PID and logs to writable location
  ln -sf /sandbox/.openclaw-data/gateway.pid /sandbox/.openclaw/gateway.pid
  ln -sf /sandbox/.openclaw-data/logs /sandbox/.openclaw/logs

  # Auto-fix config based on latest doctor checks (e.g. enabling Telegram)
  echo "[services] Running openclaw doctor --fix..." >&2
  "$OPENCLAW" doctor --fix >/dev/null 2>&1 || true
fi
echo "[services] Patching runtime configuration..." >&2
patch_runtime_config
[ -f .env ] && chmod 600 .env

# ── Non-root fallback ──────────────────────────────────────────
# OpenShell runs containers with --security-opt=no-new-privileges, which
# blocks gosu's setuid syscall. When we're not root, skip privilege
# separation and run everything as the current user (sandbox).
# Gateway process isolation is not available in this mode.
if [ "$(id -u)" -ne 0 ]; then
  echo "[gateway] Running as non-root (uid=$(id -u)) — privilege separation disabled" >&2
  export HOME=/sandbox
  if ! verify_config_integrity; then
    echo "[SECURITY] Config integrity check failed — refusing to start (non-root mode)" >&2
    exit 1
  fi
  write_auth_profile

  if [ ${#NEMOCLAW_CMD[@]} -gt 0 ]; then
    exec "${NEMOCLAW_CMD[@]}"
  fi

  # In non-root mode, detach gateway stdout/stderr from the sandbox-create
  # stream so openshell sandbox create can return once the container is ready.
  touch /tmp/gateway.log
  chmod 600 /tmp/gateway.log

  # Separate log for auto-pair in non-root mode as well.
  touch /tmp/auto-pair.log
  chmod 600 /tmp/auto-pair.log

  # Start gateway in background, auto-pair, then wait
  nohup "$OPENCLAW" gateway run --bind lan >/tmp/gateway.log 2>&1 &
  GATEWAY_PID=$!
  echo "[gateway] openclaw gateway launched (pid $GATEWAY_PID)" >&2
  start_auto_pair
  start_telegram_bridge
  print_dashboard_urls
  wait "$GATEWAY_PID"
  exit $?
fi

# ── Root path (full privilege separation via gosu) ─────────────

# Verify config integrity before starting anything
verify_config_integrity

# Write auth profile as sandbox user (needs writable .openclaw-data)
gosu sandbox bash -c "$(declare -f write_auth_profile); write_auth_profile"

# If a command was passed (e.g., "openclaw agent ..."), run it as sandbox user
if [ ${#NEMOCLAW_CMD[@]} -gt 0 ]; then
  exec gosu sandbox "${NEMOCLAW_CMD[@]}"
fi

# SECURITY: Protect gateway log from sandbox user tampering
touch /tmp/gateway.log
chown gateway:gateway /tmp/gateway.log
chmod 600 /tmp/gateway.log

# Separate log for auto-pair so gateway user can write to it
touch /tmp/auto-pair.log
chown gateway:gateway /tmp/auto-pair.log
chmod 600 /tmp/auto-pair.log

# Verify ALL symlinks in .openclaw point to expected .openclaw-data targets.
# Dynamic scan so future OpenClaw symlinks are covered automatically.
for entry in /sandbox/.openclaw/*; do
  [ -L "$entry" ] || continue
  name="$(basename "$entry")"
  target="$(readlink -f "$entry" 2>/dev/null || true)"
  expected="/sandbox/.openclaw-data/$name"
  if [ "$target" != "$expected" ]; then
    echo "[SECURITY] Symlink $entry points to unexpected target: $target (expected $expected)" >&2
    exit 1
  fi
done

# Lock .openclaw directory after symlink validation: set the immutable flag
# so symlinks cannot be swapped at runtime even if DAC or Landlock are
# bypassed. chattr requires cap_linux_immutable which the entrypoint has
# as root; the sandbox user cannot remove the flag.
# Ref: https://github.com/NVIDIA/NemoClaw/issues/1019
if command -v chattr >/dev/null 2>&1; then
  chattr +i /sandbox/.openclaw 2>/dev/null || true
  for entry in /sandbox/.openclaw/*; do
    [ -L "$entry" ] || continue
    chattr +i "$entry" 2>/dev/null || true
  done
fi

# Start the gateway as the 'gateway' user.
# Pipe to stdout so crash reasons are visible in Dokploy logs.
gosu gateway bash -c "exec \"$OPENCLAW\" gateway run --bind lan" &
GATEWAY_PID=$!
echo "[gateway] openclaw gateway launched as 'gateway' user (pid $GATEWAY_PID)" >&2

start_auto_pair
start_telegram_bridge
print_dashboard_urls

# Keep container running by waiting on the gateway process.
# This script is PID 1 (ENTRYPOINT); if it exits, Docker kills all children.
wait "$GATEWAY_PID"
