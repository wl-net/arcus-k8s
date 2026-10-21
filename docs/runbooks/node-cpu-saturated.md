# Node CPU Saturated

Severity **warning** · group Node Health · fires when runnable processes on the node have been waiting for a CPU more than 25% of the time for 15 minutes.
Rule `node-cpu-saturated` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

This is pressure stall information (`/proc/pressure/cpu`), not utilization: it
only rises when something that wants to run cannot get a CPU. A healthy node
stays near 0% however busy it is. Above 25% the services are being slowed, so
hub messages, rules and API calls take longer than they should.

Short bursts (a rollout starting several JVMs, a Cassandra repair on the same
host) do not reach the 15 minute window. Sustained pressure means the node is
too small for what it runs, or something is spinning.

## Confirm

```bash
kubectl top pods -A --sort-by=cpu
```

On the node:

```bash
cat /proc/pressure/cpu                    # avg10, avg60, avg300 in %
top -o %CPU                               # anything outside Kubernetes?
```

Check the overview dashboard for a service whose GC Time or Thread Count
jumped at the same time; a JVM collecting continuously burns a core.

## Fix

- One service spinning: `./arcuscmd.sh logs <app>` for what it is doing, then
  `./arcuscmd.sh deletepod <app>` if it looks stuck. A JVM near its heap limit
  spends its time in GC: see [Container OOM Killed](container-oom-killed.md)
  for the sizing rule.
- Something outside Kubernetes (Cassandra compaction or repair, a backup):
  wait for it or reschedule it off peak.
- Everything is busy: the CPU limits in `config/deployments/` decide who gets
  slowed. Lower the limit of something non-urgent (history-service,
  notification-services) or add CPUs.

## Related alerts

- [Node Swapping](node-swapping.md) and [Node Memory Low](node-memory-low.md) — memory shortage shows up as CPU pressure too.
