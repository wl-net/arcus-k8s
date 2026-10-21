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
`402` or a quota message is credit, a timeout is network.

## Fix

- Bad key: put the new one in `secret/` (`email.provider.apikey`) and
  `./arcuscmd.sh apply`; the secret is pushed to the cluster by apply, not by
  configure.
- Out of credit or suspended: the provider's dashboard.
- Network: `kubectl exec deploy/notification-services -- curl -sI https://api.sendgrid.com`
  (or the provider in use) to see whether the cluster can reach it.
- Sender domain not verified or DNS records changed: the provider's bounce
  reason says so; fix the SPF/DKIM records.

Notifications that failed are not retried; the user has to trigger them
again (ask for another reset email).

## Related alerts

- [Service Down](service-down.md) for notification-services — nothing sends at all.
