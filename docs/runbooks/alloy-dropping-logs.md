# Log Shipping Dropping Entries

Severity **warning** · group Monitoring Health · fires as soon as Alloy has given up on log entries in the last 10 minutes.
Rule `alloy-dropping-logs` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

Alloy collected log lines but could not deliver them to Loki after its
retries, and dropped them. Those lines are gone. The `reason` label says why:
`ingester_error` or `rate_limited` means Loki refused them
([Loki Discarding Logs](loki-discarding-logs.md) names the limit), a
connection error means Loki was down ([Monitoring Service Down](monitoring-service-down.md)),
`line_too_long` a line over Loki's limit.

## Confirm

```bash
kubectl logs <alloy pod> --since=15m | grep -iE 'error|dropped|429|400' | tail -n 20
./arcuscmd.sh logs loki | grep -iE 'error|limit' | tail -n 20
```

## Fix

- Loki was down briefly: nothing to do once it is back; the drop is the
  backlog that exceeded Alloy's retry window.
- Rate limited: a pod is logging faster than the ingestion limits in
  `config/extrafiles/loki.yaml` allow; the Log Volume by Service panel
  shows which. Quieten the service (its log level in
  `config/extrafiles/logback.xml`) or raise the limit, then `./arcuscmd.sh apply`.
- Line too long: a service printing a huge single line (a serialized
  object); fix the service or raise `max_line_size` in `loki.yaml`.
- Label or timestamp errors: the Alloy pipeline in `config/logging/alloy.yaml`
  produced something Loki rejects; `./arcuscmd.sh validate` checks the
  syntax, Loki's log has the rejection.

## Related alerts

- [Loki Discarding Logs](loki-discarding-logs.md) — the same lines from Loki's side.
- [Log Ingestion Stopped](log-ingestion-stopped.md) — when nothing gets through.
