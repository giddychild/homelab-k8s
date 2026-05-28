# Vault unseal — convert to Shamir 3-of-5

Today the Vault unseal key + root token live in **one** out-of-band location.
Lose that location = re-init Vault = every ExternalSecret in the cluster
needs rebinding + every Vault-issued cert/token reissues.  A single point of
failure for the entire secrets plane.

Fix: split the unseal key into 5 Shamir shares; require any 3 to unseal.
Distribute shares so no single fire/theft/forgetting destroys ≥3 of them.

## Why Shamir, not Auto-unseal

Auto-unseal (AWS KMS / Transit) is simpler but trades the homelab's
self-contained model for cloud dependency.  If AWS is unreachable, Vault
stays sealed and you can't bootstrap.  Shamir keeps the trust chain on-prem.

## One-time procedure (~15 min, must be done when Vault is healthy)

### 1. Confirm current state

```sh
# From mgmt-jump:
kubectl exec -n vault vault-0 -- vault status
# Look for:
#   Sealed          false
#   Total Shares    1     ← this is what we're changing
#   Threshold       1
#   HA Enabled      false
```

### 2. Rekey

`operator rekey` rotates the recovery/unseal keys without re-initializing —
all existing tokens/secrets/policies remain.

```sh
# Login first with the current root token (one you have out-of-band).
kubectl exec -it -n vault vault-0 -- sh
# inside the pod:
export VAULT_ADDR=http://127.0.0.1:8200
vault login <CURRENT-ROOT-TOKEN>

# Start rekey: ask for 5 new shares with threshold 3.
vault operator rekey -init -key-shares=5 -key-threshold=3

# Output includes a Nonce.  Now feed the CURRENT (single) unseal key:
vault operator rekey -nonce=<NONCE> <CURRENT-UNSEAL-KEY>

# Output: 5 NEW unseal key shares (base64).  RECORD ALL 5.  These are the
# only copies — Vault does NOT keep them server-side after this.
```

### 3. Distribute shares (5 separate locations)

| Share # | Location                                | Recovery scenario                  |
|---------|-----------------------------------------|------------------------------------|
| 1       | 1Password / Bitwarden personal vault    | Daily access, primary              |
| 2       | Hardware backup (encrypted USB in a desk drawer) | House intact, computer compromised |
| 3       | Fireproof safe at home (paper, sealed envelope) | House fire OK if safe survives  |
| 4       | Bank safe-deposit box (paper, sealed)   | Off-site catastrophic loss         |
| 5       | Trusted family member's encrypted vault or sealed envelope | You forget / incapacitated |

**Test the threshold:** after distribution, do a dry-run reconstruction with
3 of the 5 shares (not the ones already in 1Password — try shares 3, 4, 5).
Confirm you can read them and they're correct length (44 base64 chars each).

### 4. Update runbooks

Document in `docs/runbooks/disaster-recovery.md` (or a new
`vault-unseal.md`):
- Where each share is
- That 3 of 5 are needed to unseal
- The order of operations after a Vault pod restart

### 5. Rotate the root token

Same opportunity to rotate the root token (currently long-lived → bad
practice).  After the rekey:

```sh
vault token create -policy=root -ttl=24h
# Use the NEW token for any admin work going forward.
# Revoke the old long-lived root token:
vault token revoke <OLD-ROOT-TOKEN>
```

Better long-term: use the **root token only to bootstrap an AppRole** for
admin work; revoke root entirely.  See HashiCorp's "production hardening".

## Recovery scenario walkthrough

**Vault pod restarts (planned or otherwise):**
1. `kubectl get pods -n vault` → `vault-0` is `Running` but `0/1` ready.
2. `kubectl exec -n vault vault-0 -- vault status` → `Sealed: true`.
3. Gather 3 of the 5 shares.  From mgmt-jump:
   ```sh
   kubectl exec -it -n vault vault-0 -- sh
   vault operator unseal <SHARE-1>
   vault operator unseal <SHARE-2>
   vault operator unseal <SHARE-3>
   # Sealed: false after the 3rd.
   ```
4. ESO will resume syncing within ~30s.

**You lose 1-2 shares:** still safe (3-of-5 means you need 3).  Plan a new
rekey to issue 5 fresh shares + invalidate all old ones.

**You lose 3+ shares:** Vault stays sealed forever.  Restore from
`disaster-recovery.md` (Velero restores app data + manifests; you re-init
Vault from scratch and rebind ESO).

## Rekey vs. re-init — never confuse them

- `vault operator rekey`     — rotates unseal keys.  Data preserved.  Use this.
- `vault operator init`      — wipes Vault.  Only after total loss.
