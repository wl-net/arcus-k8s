# Email Notification Errors

Severity **warning** · group Service Health · fires when notification-services has failed to send email for 5 minutes.
Rule `notification-email-errors` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

Emails from the platform (invitations, password resets, alarm notifications
by email) are not going out. The provider is rejecting them, or cannot be
reached. Users notice when a reset email never arrives.

## Confirm

```bash
./arcuscmd.sh logs notification-services | grep -i -E 'email|sendgrid|mailgun'
./arcuscmd.sh verifyconfig                 # is the provider key present?
```

The provider's error says which it is: `401`/`403` is a bad or revoked key,
`402` or a quota message is credit, a timeout or connection error is network.

Mailgun is reached through the egress proxy (`egress-proxy:3128`), so a
network error can be the proxy rather than the provider. Its connection log
shows whether the calls got out, in Grafana Explore (Loki):

```logql
{app="egress-proxy"} |= "api.mailgun.net" | logfmt
```

`code=200` is a tunnel that opened (`flags=SI` on it only means the idle
connection was closed by the proxy afterwards); `code=503` with `flags=UF`
(upstream connection failure) is the proxy failing to reach Mailgun. No lines
at all means notification-services isn't reaching the proxy. A key or credit
problem still shows `code=200` here, since the proxy only sees the tunnel.

## Fix

- Bad key: put the new one in `secret/` (`mailgunemail.provider.apikey` for
  Mailgun, `email.provider.apikey` for SendGrid) and `./arcuscmd.sh apply`;
  the secret is pushed to the cluster by apply, not by configure.
- Out of credit or suspended: the provider's dashboard.
- Network: first [Service Down](service-down.md) for `egress-proxy` (neither
  replica ready means nothing gets out). The notification-services image has
  no curl, so test the path from a throwaway pod:
  `kubectl run egress-test --rm -i --restart=Never --image=curlimages/curl -- -sI -x http://egress-proxy:3128 https://api.mailgun.net`.
  SendGrid's client ignores the proxy settings and connects directly; drop
  the `-x` option to test that.
- Sender domain not verified or DNS records changed: the provider's bounce
  reason says so; fix the SPF/DKIM records.

Notifications that failed are not retried; the user has to trigger them
again (ask for another reset email).

## Related alerts

- [Service Down](service-down.md) for notification-services — nothing sends at all.
- [Service Down](service-down.md) for egress-proxy — no SMS, voice or Mailgun email gets out.
