# Hub Heartbeats Stale

Severity **warning** · group Service Health · fires when an online hub has gone more than 2 minutes without a heartbeat, for 3 minutes.
Rule `hub-heartbeats-stale` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

The hub registry in platform-services counts hubs that are still marked
online but whose newest heartbeat is older than `hub.staleHeartbeatSec`
(default 120 seconds, against a ~30 second heartbeat interval). A stale hub
is degraded — its commands and events may already be failing — but the
10-minute offline timeout has not removed it yet; this alert is the early
warning in that gap. The gap is only about 8 minutes, so the rule waits 3.
When the timeout removes the hub the alert clears: the hub went offline, it
did not recover, so check the online count on the Hub & IPCD Device Registry
panel before treating a resolved notification as good news.

One stale hub points at that hub or its network. All hubs going stale at
once points at the heartbeat pipeline instead: hub-bridge not forwarding,
Kafka backed up, or platform-services not consuming.

## Confirm

```bash
./arcuscmd.sh logs platform-services | grep -i heartbeat
./arcuscmd.sh logs hub-bridge | grep -i heartbeat
```

The Hub & IPCD Device Registry panel on the overview dashboard shows the
stale count next to online/disconnected, and Hub Heartbeats (/s) shows
whether heartbeats are arriving at hub-bridge at all. In a multi-datacenter
deployment only the active platform-services instance tracks hubs; the
standby reports 0.

## Fix

One hub: check its network and power; if it stays stale it will go offline
and reconnect on its own, or power-cycle it to speed that up.

Fleet-wide: heartbeats are being lost in the pipeline. Check
[Datastore Unreachable](datastore-unreachable.md) for Kafka, hub-bridge's
health (Hub Heartbeats panel, its logs), and platform-services (restarts,
partition assignments on the Active / Standby row). A hub-bridge or
platform-services restart recovers the registry state from heartbeats
within a couple of minutes.

## Related alerts

- [Datastore Unreachable](datastore-unreachable.md),
  [Session Churn High](session-churn-high.md),
  [Hub TLS Failing](hub-tls-failing.md).
