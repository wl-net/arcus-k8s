# Container OOM Killed

Severity **warning** · group Service Health · fires as soon as a container restarts after an OOMKilled exit.
Rule `container-oom-killed` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

The container went over its memory limit and the kernel killed it. Kubernetes
restarted it at once, so the service is back, but whatever it was doing at the
time (a rule run, a notification, a hub message) was lost. One kill is worth a
look in working hours; repeated kills become [Pod Crash Looping](pod-crash-looping.md).

For the Arcus JVMs the limit has to be well above `-Xmx`: the services run at
about 3 times their heap in total (128m heap, roughly 390Mi working set),
because of metaspace, threads, Netty buffers and the JIT.

## Confirm

```bash
kubectl describe pod -n <namespace> <pod>        # Last State: OOMKilled, and the limit under Limits
kubectl top pods --containers | grep <app>       # what it uses now
grep -E 'Xmx|memory' config/deployments/<app>.yaml
```

On the overview dashboard, Old Gen After GC (% of max) for the service: a
line that climbs and never comes down after a collection is a leak; a flat
line near 100% is a heap that is simply too small.

## Fix

- Limit too close to the heap: raise `resources.limits.memory` in
  `config/deployments/<app>.yaml` to about 3 times `-Xmx`, then
  `./arcuscmd.sh apply`. Check the node has room first
  (`kubectl describe node | grep -A8 'Allocated resources'`).
- Heap too small for the load (Old Gen stays near 100%): raise `-Xmx` and the
  limit together.
- A leak (Old Gen climbs across days): note the version in
  `./arcuscmd.sh history`, and restart the service on a schedule until it is
  fixed upstream.

## Related alerts

- [Pod Crash Looping](pod-crash-looping.md) — when it keeps happening.
- [Node Memory Low](node-memory-low.md) — raising limits can push the node over.
