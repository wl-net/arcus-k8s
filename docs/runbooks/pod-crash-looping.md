# Pod Crash Looping

Severity **critical** · group Service Health · fires when a container has been in CrashLoopBackOff for 10 minutes.
Rule `pod-crash-looping` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

The container keeps exiting and Kubernetes is backing off its restarts (up to
5 minutes between attempts). The service is effectively down, or running on
its previous pod if this is a rollout (then [Deployment Rollout Stuck](rollout-stuck.md)
fires too).

## Confirm

```bash
kubectl get pods -n <namespace> | grep <pod>
kubectl logs -n <namespace> <pod> -c <container> --previous    # the crash itself
kubectl describe pod -n <namespace> <pod>                      # Last State: exit code and reason
```

## Fix

By what the previous logs and Last State say:

- **OOMKilled** (exit code 137): the memory limit is too low for the heap,
  see [Container OOM Killed](container-oom-killed.md).
- **Exit code 1 with a stack trace at startup**: usually configuration. A
  missing key in `config/configmaps/arcus-config.yaml` or a Secret in
  `secret/` (`./arcuscmd.sh verifyconfig`), or a datastore it cannot reach
  ([Datastore Unreachable](datastore-unreachable.md)). Kafka topics or a
  Cassandra keyspace missing after a fresh install: `./arcuscmd.sh modelmanager`.
- **Exit code 143 or 137 without OOM**: the liveness probe killed it because
  the metrics port did not answer in time. A JVM that takes long to start on
  a loaded node can hit this; check [Node CPU Saturated](node-cpu-saturated.md)
  and the probe's `initialDelaySeconds` in `config/deployments/<app>.yaml`.
- **A new image**: `./arcuscmd.sh history` shows what changed;
  `./arcuscmd.sh rollback` or `kubectl rollout undo deployment/<app>` goes back.
- **hub-keystore-renewal or a modelmanager job**: these are Jobs, see
  [Job Failed](job-failed.md).

Once fixed, the pod recovers on its own at the next backoff; to skip the
wait, `./arcuscmd.sh deletepod <app>`.

## Related alerts

- [Service Down](service-down.md), [Workload Unavailable](workload-unavailable.md) — the effect.
- [Container OOM Killed](container-oom-killed.md) — the most common cause.
