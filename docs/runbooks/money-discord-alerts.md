# Money — Discord login & sign-up alerts

The API posts a best-effort message to a Discord webhook whenever someone
signs in (`🔓 Login: alice@example.com (from 1.2.3.4)`) or completes
registration (`🆕 New account registered: …`). Useful as a low-noise security
feed for a publicly exposed deployment. Disabled by default; the webhook URL
is the only credential and lives in Vault.

## One-time setup

### 1. Create a Discord webhook

In a Discord server you control: **Server Settings → Integrations → Webhooks →
New Webhook**. Pick the channel that should receive alerts, copy the webhook URL
(looks like `https://discord.com/api/webhooks/…/…`). Keep it secret — anyone
with the URL can post to that channel.

### 2. Store the URL in Vault

Add to the existing `secret/money/app` blob — **PATCH, not POST**, so the other
keys aren't wiped:

```bash
vault kv patch secret/money/app discord_webhook='https://discord.com/api/webhooks/…/…'
```

### 3. Enable in `values-homelab.yaml`

```yaml
externalSecrets:
  discordWebhook: true
```

Commit + push; ArgoCD syncs ESO, which adds `discord_webhook` to the
`money-secrets` Secret. The API deployment's `DISCORD_WEBHOOK_URL` env (already
wired as `optional: true`) starts resolving on the next rollout — restart the
API pods to pick it up immediately:

```bash
kubectl -n money rollout restart deploy/money-api
```

### 4. Verify

Sign in once. Within a few seconds the Discord channel should receive
`🔓 Login: <your-email> (from <your-ip>)`. If nothing arrives, check the API
logs:

```bash
kubectl -n money logs deploy/money-api --tail=50 | grep -i discord
```

`discord_notify` is fire-and-forget — failures are logged but never block the
login itself.

## Operational notes

- **No rate limiting**: every login posts a message. If you share an account
  across devices that re-auth frequently you'll see chatter — narrow the
  channel or disable until you actually need it.
- **Rotating the webhook**: re-roll the URL in Discord, `vault kv patch` the
  new value, `rollout restart deploy/money-api`. ESO refreshes the secret on
  its `refreshInterval` (1h) or immediately on a rollout.
- **Disabling**: flip `externalSecrets.discordWebhook: false` and re-sync. The
  env var becomes unresolvable; the API's `discord_notify` no-ops when the URL
  is empty.
