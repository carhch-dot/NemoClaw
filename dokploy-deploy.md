# Deploying NemoClaw to Hostinger with Dokploy

This guide walks you through deploying NemoClaw to your Hostinger VPS using Dokploy.

## Prerequisites

- Hostinger VPS with **Ubuntu 22.04+**, minimum 4 vCPU / 8 GB RAM
- **Dokploy** installed on your VPS (see below if not yet installed)
- A domain or subdomain pointed to your VPS IP (e.g. `nemoclaw.yourdomain.com`)
- **NVIDIA API key** from [build.nvidia.com](https://build.nvidia.com) → API Keys

---

## Step 1 — Install Dokploy (if not already installed)

SSH into your VPS and run:

```bash
curl -sSL https://dokploy.com/install.sh | sh
```

Dokploy will install Docker, Traefik, and its own dashboard at `http://<your-vps-ip>:3000`.

Open `http://<your-vps-ip>:3000` in your browser and complete the initial setup (admin account).

---

## Step 2 — Connect your GitHub Repository

1. In the Dokploy dashboard, go to **Settings → Git Providers**
2. Connect your GitHub account (OAuth or personal token)
3. This allows Dokploy to pull the NemoClaw repo and auto-deploy on pushes

---

## Step 3 — Create a New Project

1. Click **Create Project** → give it a name (e.g. `nemoclaw`)
2. Inside the project, click **Create Service → Docker Compose**
3. Select **GitHub** as the source and choose the **NemoClaw** repository
4. Set the **Docker Compose file path** to: `docker-compose.yml`
5. Set the **branch** to `main`

---

## Step 4 — Configure Environment Variables

In the service → **Environment** tab, add:

| Variable | Value |
|----------|-------|
| `NVIDIA_API_KEY` | Your NVIDIA API key |
| `CHAT_UI_DOMAIN` | `nemoclaw-nemoclaw-dyj9qo-b16fec-187-124-155-228.traefik.me` (or your custom domain) |
| `CHAT_UI_URL` | `http://${CHAT_UI_DOMAIN}` (use `https://` if you enabled Let's Encrypt) |
| `NEMOCLAW_DISABLE_DEVICE_AUTH` | `1` (recommended for cloud — enables auto-pair) |
| `NEMOCLAW_BUILD_ID` | `dokploy-1` (change to bust cache on rebuild) |

> **Note:** `CHAT_UI_DOMAIN` configures the Traefik router label automatically. `CHAT_UI_URL` is baked into the image for CORS configuration.

---

## Step 5 — Configure the Domain & HTTPS in Dokploy

1. In Dokploy → your service → **Domains** tab
2. Add domain: `nemoclaw.yourdomain.com`
3. Enable **HTTPS / Let's Encrypt** — Dokploy will auto-provision the certificate
4. Make sure your domain's DNS A record points to your VPS IP

---

## Step 7 — Deploy

1. In Dokploy → your service → **Deployments** tab
2. Click **Deploy**
3. Watch the build logs — the first build takes ~3–5 minutes (pulls ~2.4 GB base image)

Expected output at the end of the logs:
```
[gateway] openclaw gateway launched as 'gateway' user (pid ...)
[gateway] auto-pair watcher launched (pid ...)
[gateway] Remote UI: https://nemoclaw.yourdomain.com/#token=...
```

---

## Step 8 — Access the OpenClaw Web UI

Open your browser and navigate to:

```
https://nemoclaw.yourdomain.com
```

The page will auto-authenticate using the token embedded in the URL shown in the logs.
You'll see the OpenClaw chat interface. Type a message to start chatting with the Nemotron agent.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Build fails pulling base image | VPS has no internet access — check firewall/outbound rules |
| `Config integrity check FAILED` | Rebuild the image (change `NEMOCLAW_BUILD_ID`) |
| 502 Bad Gateway from Traefik | Container not on `dokploy-network` — check network config in compose file |
| UI loads but agent doesn't respond | Check `NVIDIA_API_KEY` is set and valid in Dokploy → Environment |
| Port 18789 not accessible | Normal — Traefik proxies it; don't expose it directly |

### View live container logs

In Dokploy → your service → **Logs** tab, or SSH into the VPS:

```bash
docker logs -f nemoclaw-nemoclaw-1
```

---

## Updating NemoClaw

Push a new commit to `main` and click **Deploy** in Dokploy (or enable **Auto Deploy** in the service settings to trigger on every push).

To rotate the auth token (security best practice), change `NEMOCLAW_BUILD_ID` to a new value and redeploy — this forces a cache-busted image rebuild with a fresh token.
