# Node Disk Filling

Severity **warning** · group Node Health · fires when a filesystem has been more than 80% full for 30 minutes.
Rule `node-disk-filling` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

A filesystem on the node is filling up. Nothing is broken yet, but the kubelet
starts evicting pods at 95%, and [Node Disk Critical](node-disk-critical.md)
fires at 90%. Deal with it in working hours.

On a node that has `/etc/rancher/k3s/config.yaml.d/arcus-image-gc.yaml` (written
by `./arcuscmd.sh k3s`) the kubelet already deletes unused images once the disk
passes 75%, so something other than old images is growing. Without that file
the kubelet waits until 85%, and old release images are the usual cause.

## Confirm

On the node named in the alert:

```bash
df -h                                   # which filesystem, how fast it moves
ls /etc/rancher/k3s/config.yaml.d/      # is arcus-image-gc.yaml there?
sudo du -xh --max-depth=2 / | sort -h | tail -n 20
```

The usual places that grow:

- `/var/lib/rancher/k3s/agent/containerd` — container images (`sudo k3s crictl images`)
- `/var/log/pods` — container logs
- `/var/lib/rancher/k3s/storage` — the Prometheus, Loki and Grafana volumes (`kubectl get pvc`)
- the home directory — old `backupconfig` tarballs and Cassandra dumps

## Fix

1. Old images: `sudo k3s crictl rmi --prune`, then run `./arcuscmd.sh k3s` on the node
   so the kubelet's 75% threshold is in place for next time.
2. Journal: `sudo journalctl --vacuum-size=200M`.
3. Container logs: a pod logging far more than the rest shows up on the
   Log Volume by Service panel of the overview dashboard; fix the service or
   lower its log level in `config/extrafiles/logback.xml`.
4. Prometheus or Loki volumes: retention is set in `config/extrafiles/prometheus.yaml`
   (30 days or 4GB) and `config/extrafiles/loki.yaml`; lower it and `./arcuscmd.sh apply`.
5. Old tarballs and backups: move them off the node.

The alert clears on its own once usage is back under 80%.

## Related alerts

- [Node Disk Critical](node-disk-critical.md) — same check at 90%, critical.
- [Node Under Pressure](node-pressure.md) — the kubelet has started evicting pods for DiskPressure.
