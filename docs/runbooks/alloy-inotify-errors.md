# Alloy Inotify Errors

Severity **warning** · group Service Health · fires when Alloy has logged "too many open files" in the last 5 minutes, for 2 minutes.
Rule `alloy-inotify-errors` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml). Evaluated from Loki.

## What it means

Alloy tails every container's log file through inotify. The node has run
out of inotify instances or watches (`fs.inotify.max_user_instances`,
`max_user_watches`) or open files, so some logs are not being collected.
Loki is missing lines, and the log-based alerts are blind for those pods.

## Confirm

```bash
kubectl logs ds/alloy --since=10m | grep 'too many open files'
```

On the node:

```bash
cat /proc/sys/fs/inotify/max_user_instances /proc/sys/fs/inotify/max_user_watches
find /proc/[0-9]*/fd -lname 'anon_inode:inotify' 2>/dev/null | wc -l      # instances in use
```

The kubelet, containerd, journald and systemd each use several; the default
128 instances is too few on a busy node.

## Fix

Raise the limit and make it stick:

```bash
sudo sysctl fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288
printf 'fs.inotify.max_user_instances=512\nfs.inotify.max_user_watches=524288\n' | sudo tee /etc/sysctl.d/99-inotify.conf
kubectl rollout restart ds/alloy
```

If the count of instances in use keeps climbing, something is leaking them;
`for p in /proc/[0-9]*; do echo $(find $p/fd -lname 'anon_inode:inotify' 2>/dev/null | wc -l) $(cat $p/comm 2>/dev/null); done | sort -n | tail`
names the process.

## Related alerts

- [Log Ingestion Stopped](log-ingestion-stopped.md) — when nothing is collected at all.
- [Log Shipping Dropping Entries](alloy-dropping-logs.md) — Alloy collects but cannot deliver.
