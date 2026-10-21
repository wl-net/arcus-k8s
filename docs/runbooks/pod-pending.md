# Pod Stuck Pending

Severity **warning** · group Service Health · fires when a pod has been Pending for 10 minutes for a reason other than an image pull.
Rule `pod-pending` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

The pod cannot start. Either the scheduler finds no node with room for its
CPU and memory requests, or something it mounts (a volume, Secret or
ConfigMap) is missing. During a rollout the old pod keeps serving, so the
service runs the previous version until this is fixed; after an eviction or
on a fresh install there is no old pod and [Workload Unavailable](workload-unavailable.md)
fires with it.

## Confirm

```bash
kubectl describe pod -n <namespace> <pod>        # Events at the end say why
kubectl describe node | grep -A8 'Allocated resources'
kubectl get pvc -A
```

## Fix

- **FailedScheduling: Insufficient cpu/memory**: the node's requests are
  full. During a rollout both the old and new pod need room. Lower a request
  in `config/deployments/` (the Arcus services ask for little; look for one
  that was raised), remove something, or add resources.
  `kubectl top pods -A` shows real use against the requests.
- **A missing ConfigMap or Secret** (`MountVolume.SetUp failed`):
  `./arcuscmd.sh verifyconfig`, then `./arcuscmd.sh apply` pushes
  configmaps and `secret/` to the cluster.
- **A PersistentVolumeClaim Pending** (the monitoring StatefulSets): the
  local-path provisioner creates it on the node; `kubectl get pods -n kube-system | grep local-path`
  and `kubectl describe pvc`.
- **Node not Ready or cordoned**: `kubectl get nodes`; `kubectl uncordon <node>`
  after a `reboot-node` that did not complete.

## Related alerts

- [Image Pull Failing](image-pull-failing.md) — the pull case, excluded from this rule.
- [Workload Unavailable](workload-unavailable.md), [Deployment Rollout Stuck](rollout-stuck.md).
