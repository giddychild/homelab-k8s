# certprep — public access via Cloudflare Tunnel (certprep.giddyland.net)

Exposes the CertPrep exam simulator at a **public** hostname without opening
any inbound ports: an in-cluster `cloudflared` dials out to Cloudflare, and
Cloudflare serves the public hostname.

> **Security posture.** The login page becomes internet-reachable. Mitigations
> in place: **registration is invite-code only** (there is no open signup path
> at all — `/auth/register` requires a code an admin minted), argon2id password
> hashing, server-side sessions in httpOnly + SameSite cookies, temporary
> account lockout after 8 failed logins, Redis-backed rate limiting on login
> (10/min) and registration (5/5min), and app-layer security headers. The
> internal LAN/Tailscale host `certprep.apps.giddyland.net` is unaffected and keeps
> working.

`cloudflare.tunnel.enabled` is already **true** in `values-homelab.yaml`, so
the remaining work is the dashboard and Vault steps below. Until the token is
in Vault, ESO cannot materialize `certprep-secrets` and both the API and
cloudflared will stay pending — that is expected, not a broken deploy.

## 0. Prerequisites

Images published to ghcr and referenced in `values-homelab.yaml`:

```bash
# from the certprep repo root
docker build -f backend/Dockerfile  -t ghcr.io/giddychild/certprep-api:0.1.0 .
docker build -f frontend/Dockerfile -t ghcr.io/giddychild/certprep-web:0.1.0 ./frontend
docker push ghcr.io/giddychild/certprep-api:0.1.0
docker push ghcr.io/giddychild/certprep-web:0.1.0
```

Note the API image builds from the **repository root**, not `backend/` — the
606-question bank under `data/source` is baked in alongside the code, which is
why the API needs no PVC.

## 1. Create the tunnel (Cloudflare Zero Trust dashboard)

1. **Zero Trust** → **Networks → Tunnels** → **Create a tunnel** → type
   **Cloudflared** → name `certprep` → **Save**.
2. On the install screen, **copy the tunnel token** (the long string after
   `--token`). That is all we need; ignore the install command.
3. Add a **Public Hostname**:
   - Subdomain `certprep`, Domain `giddyland.net` (→ `certprep.giddyland.net`).
   - **Service**: `HTTPS` → `ingress-nginx-controller.ingress-nginx.svc.cluster.local:443`
     — use **HTTPS/443, not http/80**. The Ingress force-redirects HTTP→HTTPS,
     so an http origin makes cloudflared take a 308 on every request and the
     app never loads.
   - Expand **Additional application settings**:
     - **HTTP Settings → HTTP Host Header** = **`certprep.apps.giddyland.net`**
       (the Ingress routes by host; present the host it already serves so both
       `/` → web and `/api` → api route correctly).
     - **TLS → Origin Server Name** = **`certprep.apps.giddyland.net`** (so the
       Ingress serves the matching Let's Encrypt cert and TLS validates).
   - Save. Cloudflare auto-creates the proxied `certprep.giddyland.net` DNS record.

## 2. Store the secrets in Vault (you run this)

CertPrep needs two values at `secret/certprep/app`:

| key | what it is |
|---|---|
| `secret_key` | signs session cookies — rotating it signs everyone out |
| `cf_tunnel_token` | the tunnel token from step 1 |

```bash
export VAULT_ADDR=https://vault.apps.giddyland.net
export VAULT_TOKEN=<root>

# Generate a fresh signing key; do not reuse one from another app.
SECRET_KEY=$(python -c "import secrets; print(secrets.token_urlsafe(48))")

curl -sf -X POST "$VAULT_ADDR/v1/secret/data/certprep/app" \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -d "{\"data\":{\"secret_key\":\"$SECRET_KEY\",\"cf_tunnel_token\":\"<TUNNEL_TOKEN>\"}}" \
  -o /dev/null -w 'HTTP %{http_code}\n'   # expect 200
```

If the apps-prod AppRole policy does not yet allow `secret/data/certprep/*`,
add it the same way `money` and `learnquest` are allowed.

## 3. Enable it (GitOps) — already done

Already set in `gitops/workloads/certprep/values-homelab.yaml`:

```yaml
cloudflare:
  publicHost: certprep.giddyland.net
  tunnel:
    enabled: true
```

The child Application is `gitops/apps/certprep.yaml`. Once this is pushed to
`main`, ArgoCD syncs → ESO materializes `certprep-secrets` → the
`certprep-cloudflared` Deployment (2 replicas) connects the tunnel.

## 4. Create your admin account

Registration is invite-only and there is no bootstrap account, so the first
admin is made by hand:

```bash
export KUBECONFIG=~/.kube/apps-prod.kubeconfig
kubectl -n certprep exec -it deploy/certprep-api -- \
  python -m app.cli create-admin --username seyi
# prompts for a password (minimum 10 characters, argon2id hashed)
```

Then mint invite codes for your friends from **Settings → Invite codes** in the
app. Each code is shown **once** at creation and only its hash is stored, so it
cannot be recovered later — revoke and reissue instead.

## 4b. Adding a second certification

The bank is baked into the API image, so loading another exam is a rebuild, not
a config change:

1. Stage it at `data/source/<package>/` in the certprep repo, matching the
   az104 layout — `data/` (question JSON plus `domains.json`) and `images/`.
2. Rebuild and push the API image. The Dockerfile copies **every** package
   under `data/source`, so nothing there needs editing.
3. Add an entry to `jobs.import.packages` in `values-homelab.yaml`:

   ```yaml
   jobs:
     import:
       packages:
         - { package: az104, certCode: "AZ-104", certName: "…", vendor: Microsoft }
         - { package: az305, certCode: "AZ-305", certName: "…", vendor: Microsoft }
   ```

4. Bump `image.api.tag` and push. Each package gets its own import Job on a
   successive sync wave.

A certification selector then appears in the header, and every screen —
practice, exams, statistics, readiness, history — is scoped to the selected
one. The choice is stored per user in `app_user.settings.active_cert`, so it
follows the account rather than the browser.

**Exhibits are stored per package** at `MEDIA_ROOT/<package>/`. This is not
cosmetic: exhibit filenames are the source export's own question ids
(`T1Q1_exhibit1.png`), which repeat across exports, so a flat directory would
let one exam silently overwrite another's diagrams.

## 5. Verify

```bash
export KUBECONFIG=~/.kube/apps-prod.kubeconfig
kubectl -n certprep get externalsecret certprep-secrets      # READY=True
kubectl -n certprep rollout status deploy/certprep-cloudflared
kubectl -n certprep logs deploy/certprep-cloudflared | grep -i "Registered tunnel connection"

# The bank should have imported: 606 questions, 596 imported + 10 needs_review.
kubectl -n certprep logs job/certprep-import | head -12

# End to end, from outside:
curl -s https://certprep.giddyland.net/api/health          # {"status":"ok",...}
curl -s https://certprep.giddyland.net/api/ready           # database: ok
curl -so /dev/null -w '%{http_code}\n' https://certprep.giddyland.net/login   # 200
```

## Backups

Two independent paths, protecting against different failures.

**Nightly `pg_dump` — on by default.** A CronJob at 03:20 writes a compressed
custom-format dump to its own `certprep-pg-dumps` PVC and keeps 14 days.
Self-contained, no external account. It covers a dropped table, a bad
migration, or the CNPG Cluster being deleted. It does **not** cover losing
Longhorn or the cluster, because the dumps sit on the same storage.

```bash
kubectl -n certprep get cronjob certprep-pg-dump
kubectl -n certprep create job --from=cronjob/certprep-pg-dump dump-now   # on demand
kubectl -n certprep logs job/dump-now

# Restore (destructive — it replaces the live database):
kubectl -n certprep run restore --rm -it --restart=Never \
  --image=ghcr.io/cloudnative-pg/postgresql:16.4 -- bash
#   pg_restore --clean --if-exists -h certprep-pg-rw -U certprep -d certprep /dumps/<file>
```

Note the question bank is *not* what this protects — it rebuilds from the image
in seconds. What is irreplaceable is everyone's attempt history, mastery state,
exam results and flags.

**Barman to S3 — off by default.** CNPG base backups plus continuous WAL
archiving give genuine off-site point-in-time recovery. To enable:

1. Create a **dedicated** bucket and a scoped IAM user. Do not reuse the Velero
   bucket root — sharing it breaks Velero's BackupStorageLocation.
2. Write `access_key_id` / `secret_access_key` to Vault at
   `secret/certprep/backup-s3`.
3. Set `postgres.backup.barman.enabled: true` **and** switch
   `postgres.image` to the `-system-bookworm` variant — the standard image has
   no `barman-cloud-backup` binary and archiving fails with "not found".

## Notes and gotchas

- **`/api` is routed by the Ingress**, not only by the Next proxy. The frontend
  also carries a runtime proxy at `app/api/[...path]/route.ts` for local
  development and compose. It reads `API_ORIGIN` **per request** on purpose:
  a Next `rewrites()` entry is resolved at *build* time and would bake a
  hostname into the image (the failure mode learnquest hit).
- **Rate limits are per client IP.** cloudflared forwards `CF-Connecting-IP`
  and nginx sets `X-Forwarded-For`, which the API reads. If you ever see all
  traffic sharing one login budget, check that
  `use-forwarded-headers` is on for the ingress controller.
- **Sessions are per-hostname cookies.** Signing in on
  `certprep.apps.giddyland.net` does not sign you in on `certprep.giddyland.net`; that
  is expected and harmless.
- **The exam timer is server-authoritative.** A tunnel blip or a closed laptop
  does not pause a running exam, and an exam whose deadline passes is
  auto-submitted with whatever was answered the next time anything reads it.
- **Re-running the import is safe.** It is keyed on question id and reports
  unchanged records as unchanged; the sync-wave 10 hook re-runs it on every
  ArgoCD sync by design.
- **Exhibits 404 briefly on the deploy that introduces per-package media.**
  The API rolls at wave 8 with images under `az104/`, while the database still
  holds the old flat filenames until the import at wave 10 rewrites them. It is
  a window of roughly a minute and it self-heals; nothing needs doing. It
  applies only to that one upgrade.
- **Admin screens live at `/bank` and `/settings`.** `/bank` covers search and
  editing, report triage, and the import reports that were previously only
  visible in `kubectl logs`. Editing never touches the immutable source record,
  and every change writes an attributed row visible under the question's
  History tab.
