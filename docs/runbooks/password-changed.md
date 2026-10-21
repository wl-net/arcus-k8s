# Password Changed

Severity **warning** · group Service Health · fires as soon as the platform processes a person's password change.
Rule `password-changed` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

Someone changed an account password. On a platform with a handful of
accounts every change should be one you expected; one you did not is the
first sign of a stolen credential. Confirm it in working hours, sooner if
anything else looks off.

## Confirm

```bash
./arcuscmd.sh logs platform-services | grep -i passwordchanged      # who and when
./arcuscmd.sh logs client-bridge | grep -iE 'passwordchange|changepassword'   # the session and source address
```

Ask the person.

## Fix

Expected: nothing to do.

Not expected: treat the account as compromised.

1. Change the password again from an account you control, or reset it through
   the app's forgot-password flow (goes to the account's email).
2. End the account's sessions: `./arcuscmd.sh deletepod client-bridge` drops
   every client session, which is acceptable for a small platform.
3. Review the account's places for recent changes: new persons, pins, rules
   and removed devices, in the app or `./arcuscmd.sh logs platform-services`.
4. Check the other security alerts fired around the same time.

## Related alerts

- [Unauthorized Access Attempt](unauthorized-access.md) — someone probing accounts.
- [Unexpected Hub Connections](unexpected-hubs.md) — a hub that should not be here.
