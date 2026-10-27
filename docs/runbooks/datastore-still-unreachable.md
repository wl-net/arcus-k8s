# Datastore Still Unreachable

Severity **critical** · group Service Health · fires when the blackbox exporter has not been able to open a TCP connection to a Cassandra, Kafka or ZooKeeper host for an hour.
Rule `datastore-still-unreachable` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

[Datastore Unreachable](datastore-unreachable.md) has been firing for this
host for an hour without a break. If the host answers even once in that
time, the hour starts again.

The other hosts are probably carrying the load, so nothing is broken yet, but
the datastore is one failure from an outage:

- **ZooKeeper, one member of three**: a second member out of reach loses the
  quorum, every session expires and every service exits ([ZooKeeper Session
  Expired](zookeeper-session-expired.md)).
- **Cassandra**: fewer replicas left to meet LOCAL_QUORUM.

The warning was enough while it might clear on its own. This rule pages so
that a gap like this doesn't go unattended overnight.

## Confirm

The checks in [Datastore Unreachable](datastore-unreachable.md#confirm). In
short:

```bash
./arcuscmd.sh status                      # External Services pings each host
nc -zv <host> <port>                      # from here and from the other datacenter
```

## Fix

Follow [Datastore Unreachable](datastore-unreachable.md#fix): a stopped
service, a host that is down, or the link between the sites.

If the host is down for planned work, `./arcuscmd.sh silence <duration>`
covers the time it will be away. If it is gone for good, replace the member
on the datastore side and update `.config/` (then `./arcuscmd.sh apply` and
`./arcuscmd.sh deploy`). For ZooKeeper, list every member of the new
ensemble in `zookeeper-host`.

## Related alerts

- [Datastore Unreachable](datastore-unreachable.md) — the warning that has been firing for this host.
- [Datastore Quorum Lost](datastore-quorum-lost.md) — if another host goes too.
- [ZooKeeper Session Expired](zookeeper-session-expired.md) — what losing the ZooKeeper quorum costs the services.
