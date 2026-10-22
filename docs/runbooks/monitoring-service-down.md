# Monitoring Service Down

Severity **warning** · group Service Health · fires when Prometheus has not been able to scrape one of the monitoring components for 5 minutes. Also fires on no data.
Rule `monitoring-service-down` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

Prometheus, Grafana, Loki, Alloy, kube-state-metrics, node-exporter, the
kubelet's cAdvisor endpoint or cert-manager is not answering. Users are not
affected, but the alerts that read from it are blind:

If the notification is named **DatasourceError** with `rulename = Monitoring
Service Down`, Prometheus itself is the one not answering: this rule reads
its scrape targets from Prometheus and is the only rule that turns an
evaluation error into an alert (the others keep their last state). Treat it
as Prometheus down and start with its pod.

| Down | Blind |
|---|---|
| grafana | everything; the other datacenters notice through Peer Datacenter Unreachable |
| prometheus | everything except the Loki rules (Grafana evaluates them) |
| loki, alloy | Hub Firmware Upgrade Stuck, Alloy Inotify Errors, Log Ingestion Stopped |
| kube-state-metrics | Pod Crash Looping, OOM, Image Pull, Workload Unavailable, Pending, Rollout Stuck, Job Failed, Node Not Ready, Node Under Pressure, Keystore Renewal Stale |
| node-exporter | the disk, memory, CPU and swap alerts |
| cert-manager | the two certificate alerts |

## Confirm

```bash
kubectl get pods -l app=<job>             # kube-state-metrics, node-exporter, loki, alloy, grafana, prometheus
kubectl describe pod <pod>
kubectl logs <pod> --tail=50
```

For `kubelet-cadvisor`: `kubectl get --raw /api/v1/nodes/<node>/proxy/metrics/cadvisor | head`.
For `cert-manager`: `kubectl get pods -n cert-manager`.

## Fix

- Pod crash looping or OOM killed: the generic [Pod Crash Looping](pod-crash-looping.md)
  steps; the monitoring pods have limits in `config/stateful/` and
  `config/monitoring/` too.
- A StatefulSet pod stuck (prometheus-0, loki-0, grafana-0): `kubectl delete pod <pod>`.
  Their volumes keep the data. A full volume needs its retention lowered
  (`config/extrafiles/prometheus.yaml`, `loki.yaml`).
- Grafana crash looping after an `apply`: provisioning was rejected (a bad
  alert rule, template or contact point). `kubectl logs grafana-0 --previous`
  names it; fix `config/grafana/alerting.yaml` or `.config/alert-*`,
  `./arcuscmd.sh validate`, `./arcuscmd.sh apply`, and delete the pod if the
  rollout is stuck on the broken one.
- cert-manager: `./arcuscmd.sh install cert-manager` reinstalls the pinned version.
- kubelet-cadvisor: the kubelet itself; `systemctl status k3s` on the node.

## Related alerts

- [Service Down](service-down.md) — the critical twin for the Arcus services.
- [Prometheus Storage Errors](prometheus-storage-errors.md), [Log Ingestion Stopped](log-ingestion-stopped.md).
