# Log Shipping Dropping Entries

Severity **warning** · group Monitoring Health · fires as soon as Alloy has given up on log entries in the last 10 minutes.
Rule `alloy-dropping-logs` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

Alloy collected log lines but gave up delivering them to Loki. The `reason`
label says why, and whether they are gone:

- `rate_limited`: Loki answered 429 for longer than Alloy's retry window
  ([Loki Discarding Logs](loki-discarding-logs.md) names the limit). Those
  lines are gone.
- `ingester_error`: everything else. Either Loki answered with a server
  error, or not at all, for the whole retry window (ten retries with growing
  backoff, about 8 minutes; [Monitoring Service Down](monitoring-service-down.md)),
  and those lines are gone; or Loki answered a push with a 400 because some
  entries in it were bad. Loki still stores the rest of that push, but Alloy
  doesn't retry a 400 and counts the whole batch, from every service, as
  dropped, so a handful of bad entries shows as thousands dropped while only
  those few are lost. [Loki Discarding Logs](loki-discarding-logs.md) counts
  the bad entries with the reason. Entries over 256 KB (a joined stack trace,
  a dumped payload) are truncated rather than rejected
  (`max_line_size_truncate` in `config/extrafiles/loki.yaml`).

Alloy's own log has the status and Loki's message for each dropped batch
(`final error sending batch`).

## Confirm

```bash
kubectl logs -l app=alloy --all-pods --prefix --since=15m | grep -E 'final error|dropped' | tail -n 20   # status and Loki's message, per node
./arcuscmd.sh logs loki | grep -iE 'error|limit' | tail -n 20
```

## Fix

- Loki was down briefly: nothing to do once it is back; the drop is the
  backlog that exceeded Alloy's retry window.
- Rate limited: a pod is logging faster than the ingestion limits in
  `config/extrafiles/loki.yaml` allow; the Log Volume by Service panel
  shows which. Quieten the service (its log level in
  `config/extrafiles/logback.xml`) or raise the limit, then `./arcuscmd.sh apply`.
- A 400 from Loki: the message names the entry. A line over 256 KB is now
  truncated and kept; a label or timestamp Loki rejects is below.
- `ingester_error` from an Alloy pod that has just started, with Loki
  Discarding Logs showing `too_far_behind`: a replay of lines Loki already
  has ([Loki Discarding Logs](loki-discarding-logs.md) says when it
  happens); nothing is lost.
- Label or timestamp errors: the Alloy pipeline in `config/logging/alloy.yaml`
  produced something Loki rejects; `./arcuscmd.sh validate` checks the
  syntax, Loki's log has the rejection.

## Related alerts

- [Loki Discarding Logs](loki-discarding-logs.md) — the same lines from Loki's side.
- [Log Ingestion Stopped](log-ingestion-stopped.md) — when nothing gets through.
