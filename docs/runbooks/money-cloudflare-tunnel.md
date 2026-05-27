# money — public access via Cloudflare Tunnel (money.giddyland.net)

Exposes the money app at a **public** hostname without opening any inbound
ports: an in-cluster `cloudflared` dials out to Cloudflare, and Cloudflare
serves the public hostname. **No Cloudflare Access whitelist** is configured —
the gate is the app's own login, and **self-registration is closed**
(`registrationOpen: false`), so only existing accounts (+ the demo) can get in.

> Security posture: the login page becomes internet-reachable. Mitigations in
> place: closed registration, argon2id + JWT auth, Redis-backed login
> rate-limiting, app-layer security headers. The internal LAN/Tailscale host
> `money.apps.giddyland.net` is unaffected and keeps working.

The chart pieces exist (`gitops/workloads/money/templates/cloudflared.yaml`,
gated by `cloudflare.tunnelEnabled`, default off). Enabling is the steps below.

## 1. Create the tunnel (Cloudflare Zero Trust dashboard)

1. **Zero Trust** → **Networks → Tunnels** → **Create a tunnel** → type
   **Cloudflared** → name e.g. `money` → **Save**.
2. On the install screen, **copy the tunnel token** (the long string after
   `--token` in the shown command). That's all we need; ignore the install cmd.
3. Add a **Public Hostname**:
   - Subdomain `money`, Domain `giddyland.net` (→ `money.giddyland.net`).
   - **Service**: `HTTPS` → `ingress-nginx-controller.ingress-nginx.svc.cluster.local:443`
     — use **HTTPS/443**, NOT http/80. The Ingress force-redirects HTTP→HTTPS,
     so an http origin makes cloudflared get a 308 on every request (the app
     never loads). Talking HTTPS to the Ingress avoids that.
   - Expand **Additional application settings**:
     - **HTTP Settings → HTTP Host Header** = **`money.apps.giddyland.net`**
       (the Ingress routes by host, so present the host it already serves so
       `/` → web and `/api/v1` → api both route).
     - **TLS → Origin Server Name** = **`money.apps.giddyland.net`** (so the
       Ingress serves the matching Let's Encrypt cert and TLS validates).
   - Save. Cloudflare auto-creates the `money.giddyland.net` DNS record (proxied).

## 2. Store the token in Vault (you run this)

The apps-prod AppRole policy already allows `secret/data/money/*`:

```bash
export VAULT_ADDR=https://vault.apps.giddyland.net
export VAULT_TOKEN=<root>
curl -sf -X POST "$VAULT_ADDR/v1/secret/data/money/cf-tunnel" \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -d '{"data":{"token":"<TUNNEL_TOKEN>"}}' \
  -o /dev/null -w 'HTTP %{http_code}\n'   # expect 200
```

## 3. Enable it (GitOps)

In `gitops/workloads/money/values-homelab.yaml` add:

```yaml
cloudflare:
  tunnelEnabled: true
```

Commit to `main`. ArgoCD syncs → ESO materializes `cloudflared-tunnel-token` →
the `money-cloudflared` Deployment (2 replicas) connects the tunnel.

## 4. Verify

```bash
export KUBECONFIG=~/.kube/apps-prod.kubeconfig
kubectl -n money get externalsecret cloudflared-tunnel-token   # READY=True
kubectl -n money rollout status deploy/money-cloudflared
kubectl -n money logs deploy/money-cloudflared | grep -i "Registered tunnel connection"
```

Then from anywhere (off your LAN): `https://money.giddyland.net` should load the
login page. The sign-up option is hidden; only existing accounts + the demo
("Explore the demo account") work.

## Adding a user later

Self-registration is closed. To add a family member: set
`registrationOpen: true` in `values-homelab.yaml`, commit, let them register,
then set it back to `false` and commit. (Toggling it doesn't disturb existing
sessions.)

## Rollback

Set `cloudflare.tunnelEnabled: false` (and optionally delete the tunnel in the
dashboard). The public hostname stops resolving to the app; LAN/Tailscale access
via `money.apps.giddyland.net` is unaffected throughout.
