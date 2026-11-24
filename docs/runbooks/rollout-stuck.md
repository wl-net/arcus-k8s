# Deployment Rollout Stuck

Severity **warning** · group Service Health · fires when a Deployment has reported Progressing=False for 5 minutes.
Rule `rollout-stuck` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

A new version was rolled out and its pod did not become Ready within the
10 minute progress deadline, so the Deployment gave up. The old pod keeps
serving (`maxUnavailable: 0`), so the service is up on the previous
version. [Workload Unavailable](workload-unavailable.md) does not fire in
this case, which is why this rule exists.

## Confirm

```bash
kubectl rollout status deployment/<name>
kubectl get pods -l app=<name> --sort-by=.metadata.creationTimestamp   # newest last: the new pod
kubectl describe pod <new pod>
kubectl logs <new pod>                    # add --previous if it restarted
./arcuscmd.sh history                     # what the last apply changed
```

Use `kubectl logs` on the new pod rather than `./arcuscmd.sh logs <name>`:
that picks the first Running pod, and during a stuck rollout the old pod is
Running too.

## Fix

By the new pod's state:

- CrashLoopBackOff → [Pod Crash Looping](pod-crash-looping.md).
- ImagePullBackOff → [Image Pull Failing](image-pull-failing.md).
- Pending → [Pod Stuck Pending](pod-pending.md).
- Running but never Ready: the readiness probe (`readinessProbe` in
  `config/deployments/<name>.yaml`: TCP on 9100 for most services, 9082 for
  hub-bridge, HTTP `/check` on 9081 for client-bridge and api-bridge) does
  not pass. A startup error in the log, or a JVM that needs longer than the
  probe allows on a loaded node.

To go back: `kubectl rollout undo deployment/<name>`, or for a whole release
`./arcuscmd.sh rollback` then `./arcuscmd.sh apply` (rollback only checks
out the previous commit). To retry after a fix:
`./arcuscmd.sh apply` (or `kubectl rollout restart deployment/<name>`).

The alert clears when the rollout completes or is undone.

## Related alerts

- [Workload Unavailable](workload-unavailable.md) — when the old pod is gone too.
