# Node Not Ready

Severity **critical** · group Node Health · fires when a node has not reported Ready for 5 minutes.
Rule `node-not-ready` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

The kubelet on the node has stopped reporting, or reports it cannot run pods.
On a single-node cluster this means Arcus is down or about to be. After a few
more minutes Kubernetes evicts the node's pods, and on a single node there is
nowhere for them to go.

If you can still see this alert, Grafana is running, so the node is at least
partly alive. If the node is really gone, the other datacenters notice through
[Peer Datacenter Unreachable](peer-datacenter-unreachable.md) instead.

## Confirm

```bash
kubectl get nodes
kubectl describe node <node>              # Conditions and Events at the end
```

On the node:

```bash
systemctl status k3s
sudo journalctl -u k3s -n 200 --no-pager
df -h; free -m                            # out of disk or memory is the usual reason
```

## Fix

- k3s stopped or crashed: `sudo systemctl restart k3s`. Running containers keep
  going across a k3s restart.
- Disk full: see [Node Disk Critical](node-disk-critical.md).
- Out of memory: see [Node Memory Low](node-memory-low.md).
- The kubelet cannot reach the API server (certificate expired, clock far off,
  network): the journal says which. k3s rotates its certificates on restart
  if the clock is right.
- The node is hung or lost: `./arcuscmd.sh reboot-node` from the node if you
  can log in; it drains Route 53 and silences alerts first. If you cannot,
  drain from another datacenter with `./arcuscmd.sh drain` there, then power
  cycle.

Afterwards `./arcuscmd.sh status` should show every service ready;
`./arcuscmd.sh resume` restores the weighted record if you drained.

## Related alerts

- [Node Under Pressure](node-pressure.md) — the kubelet is up but evicting.
- [Peer Datacenter Unreachable](peer-datacenter-unreachable.md) — what the other datacenters see.
