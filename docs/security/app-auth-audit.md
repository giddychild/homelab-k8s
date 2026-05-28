# Application auth audit — money + LearnQuest

Snapshot of authn/authz posture for the two user-facing apps, with concrete
gaps and a hardening plan.  Date: 2026-05-28.

## money (finance app — financial data)

| Layer                | State                                                                 | Verdict |
|----------------------|-----------------------------------------------------------------------|---------|
| Edge auth (Cloudflare Access in front of the Tunnel) | Email allow-list policy in Zero Trust dashboard | ✅ |
| Sign-up               | `registrationMode: "invite"` — invite-only, admin generates codes     | ✅ |
| Login                 | Email + password (bcrypt at rest, JWT issued)                         | ✅ |
| JWT signing           | RS256 (asymmetric); `jwt_private_key` / `jwt_public_key` in Vault     | ✅ |
| Password reset        | Email-based via Gmail SMTP (app password in Vault)                    | ✅ |
| Admin role            | Email allow-list (`adminEmails: seyiobadina@yahoo.com`)               | ✅ |
| Saved-bill credentials at rest | Fernet-encrypted (`credentialKey: true` enabled)             | ✅ |
| MFA / TOTP            | Not implemented                                                       | ❌ |
| Account lockout       | Unknown — needs check of api auth router                              | ❓ |
| CSRF on web forms     | Next.js BFF + httpOnly cookies — needs verify                         | ❓ |
| Rate limiting at API  | Not in chart — likely upstream of CF Tunnel via Cloudflare WAF        | ❓ |
| Audit log of admin actions | Not visible to me — needs check                                  | ❓ |
| Postgres encryption at rest | Longhorn writes to bare HDD; no per-row encryption beyond Fernet | ⚠ |
| Postgres backups at rest    | Barman → S3 — bucket-level SSE *must be on* (see backup posture script) | ⚠ |

**Top fixes (in priority):**
1. **MFA via TOTP** — money is your money; an invite-only no-MFA design assumes
   nobody ever phishes the invite. Add TOTP enrollment on the account-settings
   page. Library: `pyotp` (api side). ~half day of work.
2. **Run the backup S3 posture script** — `scripts/check-backup-s3-posture.sh`
   (added in this pass). If `giddyland-money-pg-backups` doesn't have default
   SSE-S3 + TLS-only policy, fix it before anything else.
3. **Verify Cloudflare Access policy is actually enforced**, not just
   defined — open an incognito window with a non-allowed Google account →
   should hit a 403 from CF before the app sees the request. Test quarterly.
4. **Add a quarterly admin-review cron** — list of accounts + last-login.
   Useful when invite codes leak.

## LearnQuest (kids' learning platform — public, ages 4-10)

| Layer                | State                                                                 | Verdict |
|----------------------|-----------------------------------------------------------------------|---------|
| Edge auth (CF Access)| Email allow-list at the Zero Trust dashboard                          | ✅ |
| Login alerts          | `loginAlerts: enabled` — Discord webhook fires on every login/signup/failure | ✅ |
| Sign-up               | `inviteCode: enabled` — parent registration requires shared code      | ✅ |
| Admin curation        | `adminAuth: enabled` — only `admin_emails` Vault key can edit Q-bank  | ✅ |
| Parent vs. kid roles  | Separate (parent owns kid profiles)                                   | ✅ |
| Public DNS            | `learn.giddyland.net` via Cloudflare Tunnel + CF Access (no direct exposure) | ✅ |
| MFA / TOTP            | Not implemented                                                       | ❌ |
| COPPA disclosures     | Unknown — needs check                                                 | ❓ |
| Content moderation    | Anthropic-generated questions; offline factory + human approval flow  | ✅ |
| Parental consent flow | Invite-code is implicit; no separate verifiable parental consent      | ⚠ |
| Postgres at rest      | Longhorn HDD (not encrypted); backups off                             | ⚠ |
| Per-pod NetworkPolicy | DISABLED in `values-homelab.yaml` (`networkPolicy.enabled: false`)    | ❌ |

**Top fixes (in priority):**
1. **Enable NetworkPolicy** — chart templates were rewritten in this pass.
   Flip `networkPolicy.enabled: true` and roll out per the runbook. Highest
   leverage because a publicly-exposed kids' app should not have an open
   blast radius to the rest of the cluster.
2. **MFA for parent accounts** — same TOTP pattern as money. Kid accounts
   stay password-only (age-appropriate).
3. **Enable Postgres backups** — `postgres.backup.enabled: true` after writing
   creds to Vault. Today the database is one HDD failure from total loss.
4. **COPPA review** — since this is publicly reachable and serves kids:
   - Is there a privacy policy linked from the sign-up page?
   - Is data retention defined (e.g. delete inactive accounts after N months)?
   - Is third-party data sharing zero (Anthropic API calls happen on `worker`
     ns — they get anonymized prompts, not kid PII)?
   These are legal questions a US-resident parent operating a kids' site
   should answer in writing.
5. **Verify Cloudflare Access enforcement** — same drill as money.

## Common gaps both apps share

- **No MFA** anywhere.  Single-factor on apps that hold financial data or kid
  profiles is the biggest auth gap in the stack.
- **No account-lockout / brute-force throttle** visible from chart values.
  Probably enforced by Cloudflare Access at the edge, but worth verifying with
  a 10-fail-attempt test.
- **No automated post-incident token rotation** — if a JWT private key leaks,
  rotation is manual.  Worth scripting.
- **Postgres encryption at rest is not on** (Longhorn doesn't encrypt by
  default).  Could enable via Longhorn volume encryption + Vault KMS, but the
  S3 backup encryption matters more (off-host attack surface).
