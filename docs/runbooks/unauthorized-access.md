# Unauthorized Access Attempt

Severity **warning** · group Service Health · fires as soon as a bridge rejects a request for a place, person or support role the session is not allowed to use.
Rule `unauthorized-access` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

A logged-in session asked for something it has no right to: a place it is
not a member of, another person's data, or a support request. Two very
different things look like this:

- a stale app session after a person was removed from a place, or an app
  with a cached place ID, which is harmless and clears on its own;
- someone enumerating places or persons with a valid login, which is a
  break-in attempt.

Volume and spread tell them apart.

## Confirm

```bash
./arcuscmd.sh logs client-bridge | grep -i unauthoriz       # or api-bridge, whichever job fired
```

Look at which person, which place and which source address. The
Authorization panel on the overview dashboard shows the rate by reason.

- One person, one place, a few attempts: stale session.
- One source, many places or persons: probing.

## Fix

Stale session: nothing, or tell the person to sign out and in.

Probing: the session is authenticated, so the credential is compromised.
Treat the account as in [Password Changed](password-changed.md) (reset the
password, drop sessions with `./arcuscmd.sh deletepod client-bridge`), and
block the source address at the router or in Traefik if it keeps coming.

## Related alerts

- [Password Changed](password-changed.md), [Unexpected Hub Connections](unexpected-hubs.md).
