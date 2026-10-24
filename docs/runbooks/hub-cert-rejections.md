# Hub Certificate Rejected

Severity **warning** · group Service Health · fires as soon as hub-bridge rejects a hub TLS handshake over its certificate.
Rule `hub-cert-rejections` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

A TLS handshake on hub-bridge's port 8082 failed over the client
certificate (`bridge.hub.ssl.cert.*`); the reason label says how:

- **blacklisted** — the certificate is on the revocation blacklist. A
  stolen, resold or factory-reset hub whose identity was revoked is trying
  to connect; hub-bridge logs it at warn.
- **rejected** — the certificate did not validate (wrong CA, expired, or
  malformed). Could be a very old hub, or something that is not a hub
  probing the port.
- **missing** — the client presented no certificate where mutual auth is
  required. Counted only when that caused the rejection, never on allowed
  cert-less handshakes.

## Confirm

```bash
./arcuscmd.sh logs hub-bridge | grep -i cert
```

The warn lines carry the certificate subject and source address. The
Connection Rejections panel on the overview dashboard shows the rate by
reason. A blacklisted subject identifies exactly which revoked hub identity
is being used.

## Fix

A legitimate hub with an expired or wrong certificate: it needs
re-registration or a firmware update; check it against
[Hub Firmware Upgrade Stuck](hub-firmware-upgrade-stuck.md).

A blacklisted certificate that keeps connecting: the revocation is doing
its job; block the source address at the router to stop the noise, and if
the certificate belonged to a hub you still own, investigate where it went.

Random internet scanners show up as `rejected` or `missing` at low volume;
confirm port 8082 is only as exposed as it must be and move on.

## Related alerts

- [Hub Authorization Violations](hub-authz-violations.md),
  [Hub TLS Failing](hub-tls-failing.md),
  [Unexpected Hub Connections](unexpected-hubs.md).
