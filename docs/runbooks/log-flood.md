# Log Flood

Severity **warning** · group Monitoring Health · fires as soon as a service has averaged more than 60000 log lines a minute over the last 5 minutes.
Rule `log-flood` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

A service is logging hundreds of times faster than it ever does under load:
a tight loop that writes a line (often with a stack trace) on every pass.
The one seen so far is a Kafka consumer polling with no partitions assigned
after the service lost its cluster membership, which throws and retries
without a pause. Other candidates are a reconnect loop against a datastore
and a scheduler retrying a failing job.

It is a warning because the flood itself hurts the monitoring more than the
users: Loki ingests it (and may drop other services' lines around it,
[Log Shipping Dropping Entries](alloy-dropping-logs.md)), the node's container
logs rotate every few seconds so `kubectl logs` loses the start of the event,
and the disk fills. The condition behind it may be critical on its own; the
repeated line says.

## Confirm

```bash
./arcuscmd.sh logs <app> | tail -n 40                   # the repeated line
./arcuscmd.sh logs <app> | grep -c 'Consumer is not subscribed'   # the known loop
kubectl get pods                                        # did it restart recently?
```

The Log Volume by Service panel on the overview dashboard shows when it
started and whether other services are in it too. It counts what Loki
ingested: a flood of very large entries can hit Loki's ingestion limit
first, in which case [Loki Discarding Logs](loki-discarding-logs.md)
(`rate_limited`) fires and the panel understates the rate.

## Fix

- Looping since a restart or a [ZooKeeper Session Expired](zookeeper-session-expired.md):
  `./arcuscmd.sh deletepod <app>`; a fresh start re-registers and takes its
  partitions. If it loops again, the datastore it is retrying against is the
  problem.
- A line that is merely chatty at normal volume: raise its logger's level in
  `config/extrafiles/logback.xml`, `./arcuscmd.sh apply`, and restart the
  service.
- Afterwards, the start of the event is in the rotated files on the node,
  `/var/log/pods/default_<pod>_*/<app>/`, which `kubectl logs` does not read.

## Related alerts

- [ZooKeeper Session Expired](zookeeper-session-expired.md) — the usual trigger.
- [Log Shipping Dropping Entries](alloy-dropping-logs.md) — collateral in Loki.
- [Node Disk Filling](node-disk-filling.md) — where it ends up.
