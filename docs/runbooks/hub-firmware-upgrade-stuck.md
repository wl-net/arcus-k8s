# Hub Firmware Upgrade Stuck

Severity **warning** · group Service Health · fires when hub-bridge has logged more than 2 firmware upgrade failures for one hub in 6 hours, with failures both in the last 2 hours and 4 to 6 hours ago.
Rule `hub-firmware-upgrade-stuck` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml). Evaluated from Loki.

## What it means

Each time the hub connects, hub-bridge compares its firmware with
`firmware.xml` (`config/extrafiles/firmware.xml`), tells it to upgrade, and
the upgrade fails. The hub keeps working on its current firmware, but it
never gets the new one, and if it is below the minimum for its model it is
refused instead. One or two failures happen (a download interrupted, a hub
rebooted); a hub still failing hours later is stuck.

## Confirm

In Grafana Explore (Loki):

```logql
{app="hub-bridge"} |= "<hub id>" |= "firmware"
```

The line `firmware upgrade failed, reason - [code] - [message]` has the hub's
reason. On a Cassandra host:

```bash
cqlsh -e "SELECT state, firmwareversion, targetversion, upgradeerrorcode, upgradeerrormessage, upgradeerrortime, lastconnected FROM production.hub_registration WHERE id = '<hub id>'"
kubectl get configmap extrafiles -o jsonpath='{.data.firmware\.xml}'
```

A `targetversion` that never changes while `upgradeerrortime` keeps moving
is the stuck pattern. Compare `firmwareversion` with the `min`, `max` and
`target` for the hub's model in `firmware.xml`.

## Fix

By the reason code:

- **Download failed / not found**: the image URL in `firmware.xml` is wrong
  or the file is missing from `static.<domain>`. `curl -I <url>` from outside.
- **Verification failed**: the image is corrupt or signed for another model;
  replace it.
- **Hub rejects it** (too old to upgrade directly, or wrong model): set a
  `target` the hub can reach, or exclude the version in `firmware.xml`.
  `./arcuscmd.sh apply` pushes the new file; hub-bridge reads it at startup,
  so `./arcuscmd.sh deletepod hub-bridge` afterwards.
- **The hub itself** (full flash, failing SD card): a reboot or a factory
  reset from the hub's button; replace it if that does not help.

The alert clears 6 hours after the last failure.

## Related alerts

- [Hub TLS Failing](hub-tls-failing.md) — if hubs cannot connect at all.
