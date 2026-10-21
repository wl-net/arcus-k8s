# Workload Unavailable

Severity **critical** · group Service Health · fires when a Deployment, StatefulSet or DaemonSet has had fewer ready pods than it wants for 10 minutes.
Rule `workload-unavailable` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

A workload is missing pods: one of them is not Ready, could not be scheduled,
or does not exist. For an Arcus service with one replica that means it is
down. Deployments roll with `maxUnavailable: 0`, so a rollout that fails does
not trigger this (the old pod keeps serving, see
[Deployment Rollout Stuck](rollout-stuck.md)); an eviction, a crash or a
node problem does.

## Confirm

```bash
kubectl get pods -n <namespace> -o wide | grep <name>
kubectl describe pod -n <namespace> <pod>        # Events at the end
./arcuscmd.sh status
```

## Fix

By the pod's state:

- **Pending** with FailedScheduling: no node has room for its requests, see
  [Pod Stuck Pending](pod-pending.md).
- **CrashLoopBackOff** → [Pod Crash Looping](pod-crash-looping.md).
- **ImagePullBackOff** → [Image Pull Failing](image-pull-failing.md).
- **Running, not Ready**: the readiness probe fails; read `./arcuscmd.sh logs <app>`.
  Usually a datastore it cannot reach ([Datastore Unreachable](datastore-unreachable.md)).
- **No pod at all**: `kubectl get deployment <name>` shows 0 desired if it was
  scaled down (`kubectl scale deployment/<name> --replicas=1`), otherwise
  `kubectl describe deployment <name>` for why the ReplicaSet cannot create one
  (a missing ConfigMap or Secret, resource quota).
- **A StatefulSet** (grafana, prometheus, loki): a pod stuck Terminating or a
  volume that cannot attach blocks the next one; `kubectl delete pod <pod>`
  usually unblocks it. `kubectl get pvc` shows the volumes.

## Related alerts

- [Service Down](service-down.md) — Prometheus' view of the same outage.
- [Node Under Pressure](node-pressure.md) — evictions take several workloads down at once.
