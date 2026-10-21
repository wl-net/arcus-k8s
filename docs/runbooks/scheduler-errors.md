# Scheduler Errors

Severity **warning** · group Service Health · fires when scheduler-service has been failing scheduled commands for 5 minutes.
Rule `scheduler-errors` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

Scheduled actions (lights at sunset, thermostat schedules, scene timers) are
erroring when they fire. A burst during a Cassandra or Kafka hiccup is
common and clears with it; errors that go on mean a schedule is broken or a
device it targets is gone.

## Confirm

```bash
./arcuscmd.sh logs scheduler-service | grep -iE 'error|exception' | tail -n 50
```

The log line names the command, the place and the error. The Scheduled
Commands and Scheduler Partitions panels on the overview dashboard show
whether the whole service is affected or one place.

## Fix

- Errors start with a Cassandra or Kafka exception: see
  [Datastore Unreachable](datastore-unreachable.md); they stop when it recovers.
- One place, one device: the schedule targets a device that was removed or is
  offline. Remove or fix the schedule in the app.
- Every command fails and the datastores are fine: the service is stuck;
  `./arcuscmd.sh deletepod scheduler-service`. If a release introduced it,
  `./arcuscmd.sh history` and `./arcuscmd.sh rollback`.
- Partitions missing from the Scheduler Partitions panel: the service lost
  its partition assignment; a restart re-registers.

## Related alerts

- [Datastore Unreachable](datastore-unreachable.md) — the usual cause of a burst.
