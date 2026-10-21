# Node Swapping

Severity **warning** · group Node Health · fires when the node has been moving more than 1 MiB/s to and from swap for 15 minutes.
Rule `node-swapping` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

Pages are moving in and out of swap continuously, so the node is short of
memory and everything on it is slower. Some swap use is normal (idle pages get
swapped out and stay there); continuous traffic is not. The JVMs are the usual
cause: each uses about 3 times its `-Xmx`, and heaps that were raised one at
a time add up.

## Confirm

```bash
kubectl top pods -A --sort-by=memory
```

On the node:

```bash
free -m
vmstat 5 6                                # si/so columns: swap in and out per second
ps -eo rss,comm --sort=-rss | head        # k3s itself is several hundred MB
```

Compare each service's working set from `kubectl top` with its memory limit in
`config/deployments/`.

## Fix

- One service well above its usual size: `./arcuscmd.sh deletepod <app>`, then
  watch whether it grows back (Old Gen After GC on the overview dashboard
  shows a leak).
- The total is just too high: lower the `-Xmx` and memory limit of a service in
  `config/deployments/` (limit about 3 times the heap), `./arcuscmd.sh apply`.
  Or add memory.
- Cassandra, Kafka or ZooKeeper on the same host: their heaps count too.

## Related alerts

- [Node Memory Low](node-memory-low.md) — the critical version when there is almost nothing left.
- [Node CPU Saturated](node-cpu-saturated.md) — swapping shows up as CPU pressure.
