# Datastore Unreachable

Severity **critical** · group Service Health · fires when the blackbox exporter has not been able to open a TCP connection to a Cassandra, Kafka or ZooKeeper host for 2 minutes.
Rule `datastore-unreachable` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

A datastore host is not accepting connections on its port. Cassandra, Kafka
and ZooKeeper run outside the cluster, at the hosts in `.config/cassandra-host`,
`kafka-host` and `zookeeper-host`; `apply` writes them to the
`prometheus-targets` ConfigMap, which is what the probe reads.

What it costs depends on which one:

- **One Cassandra host of several**: the others serve, the services keep
  running at LOCAL_QUORUM as long as enough replicas are up. Fix it today.
- **The only Cassandra host, or Kafka, or ZooKeeper**: every service that
  needs it is failing. Hubs stay connected but commands are not processed,
  rules do not fire, and the apps cannot load. Fix it now.

ZooKeeper is probed at every member in `zookeeper-host`; the services fail
over between members only if all of them are listed there ([ZooKeeper Session
Expired](zookeeper-session-expired.md) is what one member's absence costs otherwise).

The probe only tests the TCP connect; a datastore that accepts connections but
misbehaves does not fire this. Those show up as errors in the service logs and
as [Scheduler Errors](scheduler-errors.md) or a [Service Down](service-down.md)
when a service's readiness probe gives up.

## Confirm

```bash
./arcuscmd.sh status                      # External Services pings each host
nc -zv <host> <port>                      # 9042 Cassandra, 9092 Kafka, 2181 ZooKeeper
```

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

- [Service Down](service-down.md), [Workload Unavailable](workload-unavailable.md) — services that gave up.
- [Scheduler Errors](scheduler-errors.md) — the first symptom in the logs.
- [Peer Datacenter Unreachable](peer-datacenter-unreachable.md) — if the whole site is cut off.
