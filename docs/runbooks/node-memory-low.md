# Node Memory Low

Severity **critical** · group Node Health · fires when less than 10% of the node's memory has been available for 10 minutes.
Rule `node-memory-low` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

The kernel is out of memory to give. It drops page cache and swaps, so
everything on the node slows down, and once less than 100Mi is left the kubelet
reports MemoryPressure and evicts pods. The Arcus JVMs are the usual cause: each
one uses about 3 times its `-Xmx` in total, so a raised heap or memory limit in
`config/deployments/` adds up fast on a 12GB node.

## Confirm

```bash
kubectl top pods -A --sort-by=memory      # what grew inside Kubernetes
kubectl describe node <node> | grep -A8 'Allocated resources'
```

On the node:

```bash
free -m
ps -eo rss,comm --sort=-rss | head        # anything outside Kubernetes (Cassandra, Kafka, ZooKeeper, k3s itself)
```

## Fix

- A service far above its usual size: `./arcuscmd.sh deletepod <app>` restarts
  it and gives the memory back. If it climbs again, look at Old Gen After GC on
  the overview dashboard for a leak and at its logs.
- Everything is simply larger than the node: lower a service's `-Xmx` and
  memory limit in `config/deployments/`, keeping the limit about 3 times the
  heap, then `./arcuscmd.sh apply`. Or add memory to the node.
- Something outside Kubernetes grew (Cassandra on the same host, a stray
  process): deal with it there.

Memory limits in the deployments are what keep one service from taking the
node down with it, so do not raise a limit to make this alert go away.

## Related alerts

- [Node Swapping](node-swapping.md) — the slower, earlier sign of the same shortage.
- [Node Under Pressure](node-pressure.md) — the kubelet has started evicting.
- [Container OOM Killed](container-oom-killed.md) — one container over its own limit, not the node.
