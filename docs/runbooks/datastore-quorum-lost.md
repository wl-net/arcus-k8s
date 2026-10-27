# Datastore Quorum Lost

Severity **critical** · group Service Health · fires when half or more of a Cassandra, Kafka or ZooKeeper datastore's hosts (the only one, when one is listed) have not accepted TCP connections from this datacenter for 2 minutes.
Rule `datastore-quorum-lost` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

The blackbox exporter here can reach no more than half of the hosts listed
for one datastore in `.config/` (`cassandra-host`, `kafka-host` or
`zookeeper-host`). [Datastore Unreachable](datastore-unreachable.md) fires for
each missing host and names it; this rule counts them per datastore.

- **ZooKeeper**: an ensemble only serves while a majority of its members are
  in contact. The services here need a member that is in the quorum, and
  with most of them out of reach they very likely have none. Once the session
  timeout passes, every session from this datacenter expires and every
  service exits ([ZooKeeper Session Expired](zookeeper-session-expired.md)).
  If the members still have a quorum among themselves, the other datacenter's
  copies take over the cluster IDs these give up (every service is a
  singleton across datacenters), and the platform carries on from there.
- **Kafka listed with one bootstrap host**: that host is down from here, and
  the services can neither publish nor consume.
- **Cassandra**: this counts contact points, not replicas. The services keep
  working as long as LOCAL_QUORUM can be met for this datacenter's
  replicas, which `nodetool status` on any node that answers will show.

## Confirm

```bash
./arcuscmd.sh status                      # External Services pings each host
cat .config/zookeeper-host                # or cassandra-host, kafka-host: the hosts counted
nc -zv <host> <port>                      # each of them; 9042 Cassandra, 9092 Kafka, 2181 ZooKeeper
kubectl get pods                          # services restarting after their sessions expired?
```

Run the same `nc` from the other datacenter. If it reaches the hosts, this
datacenter's links to the other sites are down and the hosts are fine; if it
doesn't, the hosts are down.

For ZooKeeper, ask a member you can reach whether it is serving (this needs
`srvr` in the server's `4lw.commands.whitelist`):

```bash
echo srvr | nc -w 3 <host> 2181           # Mode: leader/follower is in a quorum;
                                          # "not currently serving requests" is not
```

## Fix

- The other datacenter reaches the hosts: fix the link between the sites
  (check the VPN or router on both ends for the time the probe started
  failing). Until then, if the other datacenter is serving, `./arcuscmd.sh
  drain` takes this one out of the weighted public record, and `./arcuscmd.sh
  resume` puts it back.
- The hosts are down: bring them back until a majority answers. ZooKeeper
  starts serving again as soon as a majority of members are up and in
  contact; the services restart on their own and register again.
- Afterwards, check `./arcuscmd.sh status` to see that every service is
  running again. A service logging `Unable to reserve cluster id` is
  the standby copy if the other datacenter holds the ID; otherwise
  `./arcuscmd.sh deletepod <app>`.

The procedure for each host is in [Datastore Unreachable](datastore-unreachable.md).

## Related alerts

- [Datastore Unreachable](datastore-unreachable.md) — each host that is not answering.
- [Datastore Still Unreachable](datastore-still-unreachable.md) — a host that has been unreachable for an hour.
- [ZooKeeper Session Expired](zookeeper-session-expired.md) — what losing the ZooKeeper quorum costs the services.
- [Peer Datacenter Unreachable](peer-datacenter-unreachable.md) — the other datacenter is cut off from here too: this site's links.
