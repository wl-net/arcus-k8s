# Hub Authorization Violations

Severity **warning** · group Service Health · fires as soon as hub-bridge refuses a hub message for a source, place or authorization violation.
Rule `hub-authz-violations` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

hub-bridge's message filter refused traffic from a connected hub
(`bridge.hub.authz.*`); the reason label says why:

- **source.mismatch** — a hub sent a message claiming another hub's source
  address. Either a spoofing attempt or a cloned/restored hub carrying
  another hub's identity. hub-bridge logs this at warn, once per session.
- **place.mismatch.platform / place.mismatch.protocol** — a hub sent a
  message for a place it is not registered to, typically a hub that was
  moved between places without re-registering.
- **adminonly.rejected** — a hub tried a message type only the platform may
  send.
- **unauthorized.platform.dropped / unauthorized.protocol.dropped** — a
  session that never completed authorization sent traffic anyway, which a
  healthy hub does not do.

## Confirm

```bash
./arcuscmd.sh logs hub-bridge
```

Find the warn lines for the violation; they carry the hub ID and claimed
source address. The Hub Authorization Violations panel on the overview
dashboard shows the rate by reason. Compare the hub ID with the hubs
registered to the place it addressed.

## Fix

A moved or re-registered hub: deregister it from the old place and register
it to the right one; the mismatches stop with the next connect.

A hub claiming another hub's address, or unauthorized traffic at volume:
treat it as hostile. Find its source IP in the hub-bridge logs and block it
at the router; if the claimed identity belongs to a real hub, check that
hub still works and consider its certificate compromised — the blacklist
feeding [Hub Certificate Rejected](hub-cert-rejections.md) is the tool for
that.

## Related alerts

- [Hub Certificate Rejected](hub-cert-rejections.md),
  [Unexpected Hub Connections](unexpected-hubs.md).
