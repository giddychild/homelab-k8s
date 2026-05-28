# money — email password reset (SMTP)

Enables the "Forgot password?" flow: a user requests a reset, gets an email with
a one-hour single-use link (`<publicBaseUrl>/reset-password?token=…`), and sets
a new password. Provider-agnostic SMTP — any server works; the simplest is a
**Gmail app password**.

The app/chart pieces exist (config + `core/email.py` + the endpoints +
`SMTP_*` env, gated by `email.enabled` / `externalSecrets.smtpPassword`).
Enabling is the steps below.

## 1. Get SMTP credentials

**Gmail (easiest):**
1. On a Google account, enable **2-Step Verification** (required for app passwords).
2. Google Account → Security → **App passwords** → create one (name it "money").
3. Note the 16-char app password. SMTP settings: host `smtp.gmail.com`, port `587`,
   user = that Gmail address, from = that Gmail address.

*(Any other SMTP works too — SES SMTP, Mailgun, etc. Just set host/port/user/from
in values and the password in Vault.)*

## 2. Store the SMTP password in Vault

```bash
export VAULT_ADDR=https://vault.apps.giddyland.net
export VAULT_TOKEN=<root>
curl -sf -X POST "$VAULT_ADDR/v1/secret/data/money/app" \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -d '{"data":{"smtp_password":"<the app password>"}}' \
  -o /dev/null -w 'HTTP %{http_code}\n'   # expect 200
```

> NOTE: `secret/money/app` already holds other keys (database_url, jwt keys, …).
> Vault KV v2 `POST .../data/...` **replaces** the whole secret, so include the
> existing keys too, or use `PATCH` (`-X PATCH` with the
> `application/merge-patch+json` content type) to add just `smtp_password`:
> `curl -sf -X PATCH "$VAULT_ADDR/v1/secret/data/money/app" -H "X-Vault-Token: $VAULT_TOKEN" -H 'Content-Type: application/merge-patch+json' -d '{"data":{"smtp_password":"<app password>"}}'`

## 3. Enable it (GitOps)

In `gitops/workloads/money/values-homelab.yaml`:

```yaml
externalSecrets:
  smtpPassword: true
email:
  enabled: true
  smtpHost: "smtp.gmail.com"
  smtpPort: 587
  smtpUser: "your.account@gmail.com"
  smtpFrom: "Money <your.account@gmail.com>"
publicBaseUrl: "https://money.giddyland.net"
```

Commit to `main`. ESO syncs `smtp_password` into `money-secrets`; the API picks
up `EMAIL_ENABLED=true` and the SMTP settings.

## 4. Verify

```bash
# Login page now shows "Forgot password?" (config advertises email_enabled):
curl -s https://money.giddyland.net/api/v1/auth/config   # email_enabled: true

# Trigger a reset for a real account, then check that inbox:
curl -s -X POST https://money.giddyland.net/api/v1/auth/forgot-password \
  -H 'Content-Type: application/json' -d '{"email":"you@example.com"}'   # 202
```

The email link → `/reset-password?token=…` → set a new password (valid 1 hour,
single-use). If no email arrives, check the API logs for `email send failed`
(`kubectl -n money logs deploy/money-api | grep email`).
