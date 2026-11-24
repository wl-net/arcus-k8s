# Prometheus Storage Errors

Severity **warning** · group Monitoring Health · fires as soon as Prometheus has failed a compaction or found a corrupt WAL segment in the last 2 hours.
Rule `prometheus-storage-errors` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

Prometheus could not compact its blocks or replay its write-ahead log.
Metrics may be missing for the affected window, and the next restart may be
slow or fail. The volume being full is the usual cause; a node that lost
power mid-write the other.

## Confirm

```bash
kubectl exec prometheus-0 -- df -h /prometheus-data
./arcuscmd.sh logs prometheus | grep -iE 'compact|wal|corrupt|no space' | tail -n 20
```

## Fix

- **Volume full**: retention is the `--storage.tsdb.retention.time` and
  `--storage.tsdb.retention.size` arguments in `config/stateful/prometheus.yaml`
  (30 days or 4GB, whichever first), next to the volume claim. Lower the
  retention or grow the volume, `./arcuscmd.sh apply`. To free space now,
  delete the oldest block directories under `/prometheus-data/data`
  (`kubectl exec prometheus-0 -- ls /prometheus-data/data`; the block names
  sort by time, leave `wal` and `chunks_head` alone) and restart the pod.
- **Corrupt WAL**: Prometheus repairs what it can on restart;
  `kubectl delete pod prometheus-0`. If it still crash loops on the WAL,
  delete `/prometheus-data/data/wal` (losing the last two hours or so). You
  can't `exec` into a crash-looping pod, so remove it on the node instead.
  `kubectl get pvc prometheus-storage-prometheus-0` gives the volume name, and
  `local-path` keeps it at
  `/var/lib/rancher/k3s/storage/<volume>_default_prometheus-storage-prometheus-0/`,
  so: `sudo rm -rf /var/lib/rancher/k3s/storage/<volume>_default_prometheus-storage-prometheus-0/data/wal`,
  then `kubectl delete pod prometheus-0`.
- **Disk errors** in the node's `dmesg`: the node's disk, see
  [Node Disk Filling](node-disk-filling.md) for where the volume lives.

## Related alerts

- [Monitoring Service Down](monitoring-service-down.md) — when it stops answering.
- [Node Disk Critical](node-disk-critical.md) — the volume shares the node's disk.
