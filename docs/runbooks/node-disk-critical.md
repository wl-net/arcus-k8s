# Node Disk Critical

Severity **critical** · group Node Health · fires when a filesystem has been more than 90% full for 5 minutes.
Rule `node-disk-critical` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

The disk is filling faster than the kubelet can clean up. At 95% the kubelet
reports DiskPressure and evicts pods, which takes Arcus services down. Free
space now, then find the cause.

## Confirm

On the node named in the alert:

```bash
df -h
sudo du -xh --max-depth=2 / | sort -h | tail -n 20
kubectl describe node <node> | grep -A5 Conditions   # DiskPressure yet?
```

## Fix

Free space immediately, in this order:

```bash
sudo k3s crictl rmi --prune              # unused images, usually the most
sudo journalctl --vacuum-size=200M
ls -la ~ /root 2>/dev/null | grep -E 'tar.gz|\.bak'   # old backups and dumps
```

Then find what grew (see [Node Disk Filling](node-disk-filling.md) for the
usual places) and fix it, or the alert comes back.

If pods were already evicted, `kubectl get pods -A` shows them as Evicted or
Pending; once there is space, `./arcuscmd.sh status` should show every service
ready again. Evicted pods can be removed with
`kubectl delete pods -A --field-selector=status.phase=Failed`.

If the node does not have `/etc/rancher/k3s/config.yaml.d/arcus-image-gc.yaml`,
run `./arcuscmd.sh k3s` once space is back so the kubelet cleans images from
75% on. The restart it does keeps running containers going.

## Related alerts

- [Node Disk Filling](node-disk-filling.md) — the 80% warning that came first.
- [Node Under Pressure](node-pressure.md) — eviction has started.
- [Pod Stuck Pending](pod-pending.md) — evicted pods that cannot come back.
