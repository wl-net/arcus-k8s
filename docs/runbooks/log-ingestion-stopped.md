# Log Ingestion Stopped

Severity **warning** · group Service Health · fires when Loki has received no log lines from any pod for 15 minutes (for 5 minutes).
Rule `log-ingestion-stopped` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml). Evaluated from Loki.

## What it means

Nothing is reaching Loki. Users are not affected, but there are no logs to
debug with, and every alert evaluated from Loki ([Hub Firmware Upgrade Stuck](hub-firmware-upgrade-stuck.md),
[Alloy Inotify Errors](alloy-inotify-errors.md)) is blind. Alloy (the
collector DaemonSet) is down or cannot push, or Loki is refusing everything.

## Confirm

```bash
kubectl get pods -l app=alloy
kubectl get pod loki-0
kubectl logs ds/alloy --since=15m | tail -n 50       # push errors
kubectl logs loki-0 --since=15m | tail -n 50
```

Loki answering `503` on `/ready` for about 15 seconds after it starts is
normal (it waits for the ingester). Longer than that is not.

## Fix

- Alloy pod not running: `kubectl describe pod -l app=alloy`; a config
  error after a change to `config/logging/alloy.yaml` shows in its log
  (`./arcuscmd.sh validate` checks that file with `alloy validate`).
- Alloy up, pushes failing: the error names the cause. Connection refused
  means Loki is down ([Monitoring Service Down](monitoring-service-down.md));
  `429` or `400` means Loki is rejecting ([Loki Discarding Logs](loki-discarding-logs.md)).
- Loki stuck: `kubectl delete pod loki-0`. Its volume keeps the data; a
  full volume (`kubectl exec loki-0 -- df -h /loki`) needs the retention in
  `config/extrafiles/loki.yaml` lowered.
- Alloy collects nothing because inotify ran out: [Alloy Inotify Errors](alloy-inotify-errors.md).

The alert clears once lines arrive again. Lines logged while collection was
down are picked up from the files if the pods still exist; Alloy keeps
positions.

## Related alerts

- [Monitoring Service Down](monitoring-service-down.md) for loki or alloy.
- [Log Shipping Dropping Entries](alloy-dropping-logs.md), [Loki Discarding Logs](loki-discarding-logs.md).
