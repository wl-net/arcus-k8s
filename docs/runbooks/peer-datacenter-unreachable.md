# Peer Datacenter Unreachable

Severity **critical** · group Service Health · fires when a check of another datacenter has failed for 5 minutes.
Rule `peer-datacenter-unreachable` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

This cluster checks the other datacenters named in `.config/peer-admin-domains`:
their Grafana's `/api/health`, and their public hostnames (the domain,
`client.` and `static.`) at that datacenter's own address, so it does not
matter where the weighted public record points. One of those checks fails:

- **Only `/api/health`**: that datacenter's monitoring is down. Its services
  may be fine, but it cannot alert on its own, so this cluster is its only
  watch until it is back.
- **The public hostnames**: that datacenter is not serving. Its Route 53
  health check should have taken it out of the weighted record; if not,
  users and hubs that land there are failing.
- **Everything**: the site is off the network or powered off.

## Confirm

```bash
curl -sS https://<peer admin domain>/api/health
curl -sSI --resolve <domain>:443:<peer address> https://<domain>/
```

From the peer, if you can reach it: `./arcuscmd.sh status` and `./arcuscmd.sh check`.
Its Route 53 health check status is in the AWS console.

## Fix

- Monitoring only: on the peer, `kubectl get pods | grep -E 'grafana|prometheus'`
  and [Monitoring Service Down](monitoring-service-down.md) there.
- Serving failed, health check still passing or record not weighted: drain it
  (`./arcuscmd.sh drain` on the peer, or edit the weighted record by hand)
  so traffic comes here, then fix it as a [Public Endpoint Unreachable](public-endpoint-unreachable.md)
  on that cluster.
- Site unreachable: power, uplink, router. Until it is back this datacenter
  carries the hubs; watch [Unexpected Hub Connections](unexpected-hubs.md),
  which fires when they arrive, and raise `.config/expected-hubs` if needed.

The peer's checks fail here too when this cluster's own network is down; if
every peer fails at once, suspect this side first.

## Related alerts

- [Public Endpoint Unreachable](public-endpoint-unreachable.md) — this cluster's own public URLs.
- [Unexpected Hub Connections](unexpected-hubs.md) — the peer's hubs arriving here.
