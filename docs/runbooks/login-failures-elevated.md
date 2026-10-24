# Login Failures Elevated

Severity **warning** · group Service Health · fires when password logins have failed with unknown accounts or bad credentials more than 10 times in 15 minutes, for 5 minutes.
Rule `login-failures-elevated` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

The authentication realm is counting password login failures by cause
(`security.login.failed.*`), and one of the two attack-shaped causes is
elevated:

- **unknown_account** — logins for email addresses that do not exist. At
  volume this is account enumeration or credential stuffing: someone
  replaying a leaked credential list to see which addresses have accounts
  here.
- **bad_credentials** — the account exists but the password is wrong.
  Spread over one account this is targeted guessing; a person who forgot
  their password looks the same but stops after a few tries (and usually
  resets it instead).

The counters are kept in the realm because Shiro's multi-realm
authenticator collapses the specific cause before the bridges see it, so
the bridge-level `authentication.failed` counters cannot tell these apart.

## Confirm

```bash
./arcuscmd.sh logs client-bridge | grep -i "login\|authent"    # or api-bridge
```

The Login Failures by Cause panel on the overview dashboard shows the rate
and cause. Look at the usernames and source addresses on the failures:

- many different addresses from one source: credential stuffing or
  enumeration;
- one account failing repeatedly: a person, or an app with a saved old
  password, retrying.

## Fix

A person retrying: nothing, or help them reset the password.

An attack: block the source address at the router or in Traefik. If any
tried account also shows successful logins around the same time, treat that
account as compromised: reset its password and drop sessions with
`./arcuscmd.sh deletepod client-bridge`. Rising successes after failures is
the pattern [Password Changed](password-changed.md) and
[Unauthorized Access Attempt](unauthorized-access.md) exist to catch.

## Related alerts

- [Unauthorized Access Attempt](unauthorized-access.md),
  [Password Changed](password-changed.md),
  [PIN Verification Failures](pin-verify-failures.md).
