# Alert Notifications Failing

Severity **critical** · group Monitoring Health · fires as soon as a Grafana contact point has failed to deliver in the last 15 minutes.
Rule `grafana-notifications-failing` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

Alerts are firing without reaching anyone through that integration. If
Discord fails and Pushover works, you still hear about critical alerts; if
the only configured integration fails, nothing arrives, including this
alert, which is why it is worth looking at Grafana now and then.

## Confirm

In Grafana: Alerting → Contact points → the failing one → Test. The error
is shown there and in the log:

```bash
./arcuscmd.sh logs grafana | grep -iE 'notif|webhook|pushover' | tail -n 20
```

- `401`/`404` from Discord: the webhook was deleted or rotated.
- `400` with `invalid token`/`invalid user` from Pushover: the keys.
- `429`: rate limited; Discord allows a few requests a second per webhook.
- Timeouts: the cluster cannot reach discord.com / api.pushover.net.

## Fix

- New webhook or keys: put them in `.config/alert-discord-webhook`,
  `.config/alert-pushover-user-key` and `.config/alert-pushover-api-token`,
  then `./arcuscmd.sh apply`. `apply` provisions the contact points from them
  (and `./arcuscmd.sh validate` first catches a broken template).
- Contact points set up by hand in Grafana (a datacenter without
  `.config/alert-*`): edit them in the UI.
- Network: `kubectl exec grafana-0 -c grafana -- curl -sI https://discord.com`.
- Rate limited: notifications are grouped by alert name with a 5 minute
  group interval (in `_grafana_notifications`, `script/deploy.sh`), so a
  storm comes from many different alerts; fix the storm.

## Related alerts

- [Monitoring Service Down](monitoring-service-down.md) — Grafana itself.
