# Node Under Pressure

Severity **critical** · group Node Health · fires when a node has reported MemoryPressure, DiskPressure or PIDPressure for 5 minutes.
Rule `node-pressure` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

The kubelet has crossed one of its eviction thresholds (less than 100Mi of
memory, less than 5% or 10% of disk, or near the PID limit). It is evicting
pods and refusing to schedule new ones, so Arcus services are going down one
by one until the pressure is gone.

## Confirm

```bash
kubectl describe node <node>              # Conditions, and Events show what it evicted
kubectl get pods -A --field-selector=status.phase=Failed
```

On the node, depending on the condition:

```bash
free -m                                   # MemoryPressure
df -h                                     # DiskPressure (also check inodes: df -i)
ps -e | wc -l; cat /proc/sys/kernel/pid_max   # PIDPressure
```

## Fix

- DiskPressure: free space now, see [Node Disk Critical](node-disk-critical.md).
- MemoryPressure: see [Node Memory Low](node-memory-low.md). Restarting the
  largest JVM (`./arcuscmd.sh deletepod <app>`) is the fastest relief.
- PIDPressure: something is forking without end. `ps -eo pid,ppid,comm --sort=ppid`
  on the node, or `for p in $(kubectl get pods -o name); do echo $p $(kubectl exec $p -- ps -e | wc -l); done`
  to find the pod, then delete it.

The condition clears on its own once the resource is back under the threshold;
the kubelet then runs the pods it evicted again. Evicted pods are left in
Failed state and can be removed with
`kubectl delete pods -A --field-selector=status.phase=Failed`.

## Related alerts

- [Node Disk Critical](node-disk-critical.md), [Node Memory Low](node-memory-low.md) — the cause.
- [Workload Unavailable](workload-unavailable.md), [Pod Stuck Pending](pod-pending.md) — the effect.
