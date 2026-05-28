# Cloudflare Access in front of admin UIs

You already use Cloudflare Access for the public apps (`money.giddyland.net`,
`learn.giddyland.net`) via Cloudflare Tunnel.  The admin UIs
(Grafana / ArgoCD / Vault) are currently LAN + Tailscale only — anyone with a
LAN device or Tailnet membership reaches the login screen.

This runbook puts Cloudflare Access on top, adding edge-enforced MFA + SSO
(Google) for free, without exposing the apps' login forms publicly.

## What you get

| UI       | Path                                      | After                                          |
|----------|-------------------------------------------|------------------------------------------------|
| Grafana  | `grafana.apps.giddyland.net` (LAN/TS only)| `grafana.giddyland.net` → CF Access → Tunnel → Grafana |
| ArgoCD   | `argocd.apps.giddyland.net`               | `argocd.giddyland.net`  → CF Access → Tunnel → ArgoCD  |
| Vault    | `vault.apps.giddyland.net`                | Stays LAN/Tailscale ONLY — see "Why not Vault" |

CF Access policy: email allow-list (`seyi.obadee@gmail.com`) + Google IdP for
MFA at the IdP layer.  Even if someone has the app's password, they hit the
Google login + 2FA wall first.

## Why not Vault

Vault's auth model already requires the root token or AppRole creds — adding
a second factor at CF Access is fine, but Vault is the bootstrap.  If the
Vault edge breaks, *every other app's* secrets fail to sync.  Keep Vault
reachable only via LAN/Tailscale where you control all the moving parts.

## Steps (one-time, ~30 min)

### 1. Create a second Cloudflare Tunnel for admin UIs (or reuse the LearnQuest one)

Easiest: spin up a new `cloudflared` Deployment in `cloudflared-admin` ns
that points at the existing ingress-nginx + uses Host-header overrides for
each hostname.

```yaml
# kubernetes/bootstrap/cloudflared-admin/deployment.yaml — sketch
apiVersion: apps/v1
kind: Deployment
metadata: { name: cloudflared, namespace: cloudflared-admin }
spec:
  replicas: 2
  selector: { matchLabels: { app: cloudflared } }
  template:
    metadata: { labels: { app: cloudflared } }
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:2026.5.2
          args: ["tunnel", "--no-autoupdate", "run"]
          env:
            - name: TUNNEL_TOKEN
              valueFrom:
                secretKeyRef: { name: cloudflared-admin-token, key: token }
```

Add an ExternalSecret under `gitops/workloads/eso-config/` that pulls
`secret/cloudflare/admin-tunnel-token` into `cloudflared-admin-token`.

### 2. In the Cloudflare Zero Trust dashboard

**Networks → Tunnels → Create tunnel → "cloudflared-admin"**, copy the token
into Vault at `secret/cloudflare/admin-tunnel-token` (key: `token`).

**Public hostnames** on that tunnel:
| Hostname                       | Service URL                                          | HTTP host header                  |
|--------------------------------|------------------------------------------------------|-----------------------------------|
| `grafana.giddyland.net`        | `https://ingress-nginx-controller.ingress-nginx:443` | `grafana.apps.giddyland.net`      |
| `argocd.giddyland.net`         | `https://ingress-nginx-controller.ingress-nginx:443` | `argocd.apps.giddyland.net`       |

Tick "no TLS verify" on the service connection (the upstream cert is for the
`.apps.` hostname, not the public one — CF handles the public cert).

### 3. Access policy

**Access → Applications → Add an application → Self-hosted**:
- Application domain: `grafana.giddyland.net` → policy:
  - Action: Allow
  - Include: Emails → `seyi.obadee@gmail.com`
  - Require: Authentication method → Google (set up the Google IdP first in
    Settings → Authentication if you haven't)
- Repeat for `argocd.giddyland.net`.

Set the session duration to 8 hours (re-auth daily).

### 4. Verify

```sh
# Incognito → grafana.giddyland.net
# Expected: Google sign-in (NOT Grafana login form)
# After successful Google login: Grafana login appears.
# That's two-factor: CF Access + Google + Grafana password.

# Negative test: log in with a non-allowed Google account
# Expected: 403 from CF before reaching Grafana.
```

### 5. Lock down direct LAN paths (optional)

Once CF Access works, you can decide whether to also keep LAN/Tailscale
access to the `.apps.giddyland.net` hostnames.  Recommendation: KEEP THEM.
If Cloudflare is having a bad day, you can still admin the cluster from your
laptop on the LAN.  Defense in depth, not exclusion.

## Cost

Cloudflare Access free tier: 50 users.  Tunnel: unlimited.  $0/month for
single-admin homelab.

## Maintenance

- Rotate the Google IdP `client_secret` annually.
- Audit the Access policy "Allow" list quarterly.
- If you add a new admin email, edit the policy in CF Zero Trust dashboard;
  no GitOps roundtrip needed.
