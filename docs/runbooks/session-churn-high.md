# Session Churn High

Severity **warning** · group Service Health · fires when a bridge has closed more than 15 sessions younger than 60 seconds in 15 minutes, for 5 minutes.
Rule `session-churn-high` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

Sessions on the named bridge are being created and torn down quickly
(`bridge.sessions.shortlived` counts destroys under 60 seconds): a client
or hub is stuck in a connect/drop loop. The device behind it looks offline
or flapping to its user, and the loop burns bridge and platform capacity.
Common causes: a hub with broken networking reconnecting endlessly, an app
or integration with bad credentials retrying in a tight loop, or a bridge
dropping sessions itself (out of memory, failing platform bus).

## Confirm

```bash
./arcuscmd.sh logs <job>        # client-bridge, api-bridge or hub-bridge
```

The Session Duration panel on the overview dashboard shows p50/p95 lifetime
falling when churn starts, and Sessions Opened / Closed shows the loop as
matching opened/closed volume. In the logs, look for the same source
address, person or hub ID connecting over and over; for hub-bridge the Hub
Connect / Disconnect Events panel names the hub.

## Fix

One client or hub looping: fix or power-cycle the device, or have the user
sign out and in; a client retrying bad credentials also shows on
[Login Failures Elevated](login-failures-elevated.md).

Many sessions churning at once: the bridge itself is the problem — check
its memory and restarts (`kubectl get pods`, the JVM Memory row on the
overview dashboard) and the ZooKeeper/Kafka alerts; a bridge that cannot
reach the platform bus accepts connections and then drops them.

## Related alerts

- [Login Failures Elevated](login-failures-elevated.md),
  [Hub Heartbeats Stale](hub-heartbeats-stale.md),
  [ZooKeeper Session Expired](zookeeper-session-expired.md).
