# ZooKeeper Session Expired

Severity **critical** · group Service Health · fires as soon as a service has logged that its ZooKeeper session expired in the last 10 minutes.
Rule `zookeeper-session-expired` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

Every Arcus service holds its cluster membership as ephemeral nodes in
ZooKeeper, under a session it keeps alive with heartbeats. When the session
expires, ZooKeeper deletes those nodes, the service loses its cluster ID and
the platform partitions it owned, and it exits on purpose (`SHUTTING DOWN --
Lost cluster service id`, exit code 255). Kubernetes restarts it, it
re-registers, and work resumes; nothing it owned was processed in between.
The services share one ZooKeeper, so usually all of them go at once, and the
whole platform is out for the minute or so they take to come back. Hubs
reconnect on their own; a person in the app sees requests fail meanwhile.

A session is global to the ensemble, not to one server. A client whose
connect string lists every member fails over to another one in under a second
when its server goes away, and keeps the session. A client with a single
member listed just waits, and once the server-side session timeout passes the
session is gone. So this alert means one of:

- `.config/zookeeper-host` names one member and that member was unreachable
  for longer than the session timeout (a restart, a network path to it, a
  follower that dropped out of the quorum for a few seconds).
- The whole ensemble was unreachable from this node for that long
  ([Datastore Unreachable](datastore-unreachable.md) fires too if it lasted
  2 minutes).
- The service itself stalled for that long (a long GC pause; the JVM Memory
  panels on the overview dashboard show the heap pinned at its limit).

## Confirm

```bash
kubectl get pods                                        # every service restarted at the same second?
./arcuscmd.sh logs <app> --previous | grep -iE 'zookeeper|cluster'   # the expiry and the exit
./arcuscmd.sh logs <app> | grep -iE 'Connected to zookeeper|cluster id'  # did it come back?
cat .config/zookeeper-host                              # one member, or the ensemble?
```

The ZooKeeper Client Events panel on the overview dashboard shows the
timeouts leading up to the expiry and whether they recur at a fixed interval.

On the ZooKeeper servers, the minute before the expiry in each one's log: a
follower logging `Exception when following the leader` and election
notifications (`n.state:LOOKING`) is a member that lost the leader, and the
services connected to it were cut off while it rejoined.

## Fix

- The services recover on their own once they can reach ZooKeeper; check
  `./arcuscmd.sh status` that every one is running and none is stuck
  logging `Unable to reserve cluster id`. (platform-services is a singleton
  across datacenters; on the standby datacenter that message is normal.)
- One member in `.config/zookeeper-host`: put the whole ensemble in it,
  comma-separated, then `./arcuscmd.sh apply` and `./arcuscmd.sh deploy`.
  After that a single member dropping out costs a sub-second failover.
- A member that keeps dropping out of the quorum: its log says why (a
  network path to the leader, a `syncLimit` too short for the link, a GC
  pause on that host). That is fixed on the ZooKeeper side.
- A service restart loop after the expiry, or a Log Flood from it:
  `./arcuscmd.sh deletepod <app>`.

## Related alerts

- [Datastore Unreachable](datastore-unreachable.md) — the probed member could not be reached at all.
- [Datastore Quorum Lost](datastore-quorum-lost.md) — most of the ensemble out of reach from this datacenter, the usual cause of every service expiring at once.
- [Log Flood](log-flood.md) — a service that lost its partitions and is retrying in a tight loop.
- [Service Down](service-down.md), [Workload Unavailable](workload-unavailable.md) — a service that did not come back.
