# PIN Verification Failures

Severity **warning** · group Service Health · fires when place PIN checks have mismatched more than 5 times in 15 minutes.
Rule `pin-verify-failures` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

Someone is submitting wrong PINs (`bridge.<name>.pin.verify.mismatched`). A
place PIN is four digits — 10,000 possibilities — and guards alarm disarm
and door lock codes, so sustained guessing is worth taking seriously. A
mismatch surfaces to the app as a generic HTTP 500, so this counter is the
only operational signal of PIN guessing; nothing else gets loud.

A person who forgot their PIN produces a few mismatches that stop; an
attack produces steady volume, often against more than one place.

## Confirm

```bash
./arcuscmd.sh logs client-bridge | grep -i pin
```

The PIN Verification panel on the overview dashboard shows the mismatch
rate next to successes. Identify the person and source address making the
attempts, and whether one place or several are being tried.

## Fix

A person who forgot their PIN: have them reset it in the app, nothing else.

Guessing: the session is authenticated, so the account's credential may be
compromised. Reset the account's password, drop sessions with
`./arcuscmd.sh deletepod client-bridge`, change the place PIN, and block
the source address at the router or in Traefik if it keeps coming. Check
the place's recent history for disarms or lock operations that succeeded.

## Related alerts

- [Login Failures Elevated](login-failures-elevated.md),
  [Unauthorized Access Attempt](unauthorized-access.md).
