# Datastore Unreachable

Severity **warning** · group Service Health · fires when the blackbox exporter has not been able to open a TCP connection to a Cassandra, Kafka or ZooKeeper host for 2 minutes.
Rule `datastore-unreachable` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

A datastore host is not accepting connections on its port. Cassandra, Kafka
and ZooKeeper run outside the cluster, at the hosts in `.config/cassandra-host`,
`kafka-host` and `zookeeper-host`; `apply` writes them to the
`prometheus-targets` ConfigMap, which is what the probe reads.

This alert is a warning because one host out of several costs nothing yet:

- **One Cassandra host of several**: the others serve, and the services keep
  running at LOCAL_QUORUM as long as enough replicas are up.
- **One ZooKeeper member of three**: the other two keep the quorum. Clients
  connected to the missing member move to another one in seconds and keep
  their sessions, provided every member is listed in `zookeeper-host`
  ([ZooKeeper Session Expired](zookeeper-session-expired.md) is what one
  member's absence costs otherwise).

It does leave the datastore one failure from an outage, so two rules page:
[Datastore Quorum Lost](datastore-quorum-lost.md) as soon as half or more of a
datastore's hosts are unreachable (which includes the only host of one listed
alone, such as `kafka-host`), and [Datastore Still
Unreachable](datastore-still-unreachable.md) when this one has stayed
unreachable for an hour.

The probe runs from this datacenter, so a broken link between sites looks the
same as a host that is down. If the other datacenter still reaches the host,
it's the path.

The probe only tests the TCP connect; a datastore that accepts connections but
misbehaves does not fire this. Those show up as errors in the service logs and
as [Scheduler Errors](scheduler-errors.md) or a [Service Down](service-down.md)
when a service's readiness probe gives up.

## Confirm

```bash
./arcuscmd.sh status                      # External Services pings each host
nc -zv <host> <port>                      # 9042 Cassandra, 9092 Kafka, 2181 ZooKeeper
```

Run the same `nc` from the other datacenter, or check whether its Datastore
Unreachable fired for the same host. Only one datacenter failing points at
the link between the sites (a VPN tunnel, a router), not the host.

On the datastore host:

```bash
systemctl status cassandra                # or kafka, zookeeper
sudo ss -ltnp | grep <port>               # is anything listening?
nodetool status                           # Cassandra: ring state
```

The services' view: `./arcuscmd.sh logs platform-services | grep -iE 'NoHostAvailable|kafka|zookeeper|connection'`.

## Fix

- Service stopped: start it (`sudo systemctl start cassandra`). Cassandra
  takes a few minutes to replay its commit log before it listens.
- Host down: bring it back. If it is gone for good, point `.config/` at the
  remaining hosts and `./arcuscmd.sh apply`; the services pick up the new
  contact points when they restart (`./arcuscmd.sh deploy`).
- Reachable from the other datacenter but not this one: the link between
  the sites. Check its VPN or router on both ends for the time the probe
  started failing; the datastore needs nothing.
- Listening but refusing: disk full (`df -h`), out of file descriptors, or a
  firewall change between the cluster and the host. Cassandra refuses
  connections while a node is overloaded or in a long GC pause;
  `nodetool status` and its log say.
- The host or port in `.config/` is wrong (after a move): fix it,
  `./arcuscmd.sh apply`, `./arcuscmd.sh deploy`.

After a Cassandra outage, check `./arcuscmd.sh status` for services that did
not reconnect on their own; the Cassandra driver retries, but a pod that fell
over its readiness probe may need `./arcuscmd.sh deletepod <app>`.

## Related alerts

- [Datastore Quorum Lost](datastore-quorum-lost.md) — half or more of the datastore's hosts are unreachable.
- [Datastore Still Unreachable](datastore-still-unreachable.md) — this host has been unreachable for an hour.
- [Service Down](service-down.md), [Workload Unavailable](workload-unavailable.md) — services that gave up.
- [Scheduler Errors](scheduler-errors.md) — the first symptom in the logs.
- [Peer Datacenter Unreachable](peer-datacenter-unreachable.md) — if the whole site is cut off.
