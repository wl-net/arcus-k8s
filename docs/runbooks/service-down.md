# Service Down

Severity **critical** · group Service Health · fires when Prometheus has not been able to scrape a service, or a blackbox check has failed, for 5 minutes. Also fires on no data.
Rule `service-down` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

A scrape job is down. For an Arcus service (`hub-bridge`, `platform-services`,
…) that means no pod of it is ready: users or hubs are affected now. For a
`blackbox-*` job it means the blackbox exporter itself could not be scraped;
the checks it runs have their own alerts ([Datastore Unreachable](datastore-unreachable.md),
[Public Endpoint Unreachable](public-endpoint-unreachable.md), …).

The monitoring stack has its own, warning-level version of this alert:
[Monitoring Service Down](monitoring-service-down.md).

## Confirm

```bash
./arcuscmd.sh status                      # which pods are not ready
kubectl get pods -l app=<app> -o wide
kubectl describe pod <pod>                # Events at the end; Last State if it restarted
./arcuscmd.sh logs <app>
```

The job name is the app label of the deployment. The Service Up/Down panel
on the overview dashboard shows every job at once.

## Fix

Follow what the pod is doing:

- **CrashLoopBackOff** → [Pod Crash Looping](pod-crash-looping.md).
- **OOMKilled** in Last State → [Container OOM Killed](container-oom-killed.md).
- **ImagePullBackOff** → [Image Pull Failing](image-pull-failing.md).
- **Pending** → [Pod Stuck Pending](pod-pending.md).
- **Running but not Ready**: the readiness probe (TCP on the metrics port) is
  failing. The logs usually show a startup error, most often a Cassandra,
  Kafka or ZooKeeper connection problem, in which case check for
  [Datastore Unreachable](datastore-unreachable.md) first. If the service is
  simply stuck, `./arcuscmd.sh deletepod <app>` restarts it.
- **The pod looks healthy** but Prometheus still cannot scrape it: check the
  metrics port with `kubectl exec <pod> -- curl -s localhost:9100/metrics | head`
  and the Prometheus targets page (`kubectl port-forward svc/prometheus-service 9080:9080`,
  then http://localhost:9080/targets).

A just-deployed version that does not come up: `./arcuscmd.sh rollback`, or
`kubectl rollout undo deployment/<app>` for one service.

## Related alerts

- [Workload Unavailable](workload-unavailable.md) — the same situation seen from the Deployment.
- [Monitoring Service Down](monitoring-service-down.md) — for Prometheus, Grafana, Loki and friends.
