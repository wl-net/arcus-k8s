# Hub TLS Failing

Severity **critical** · group Service Health · fires when the blackbox exporter has not been able to complete a TLS handshake with hub-bridge on port 8082 for 5 minutes.
Rule `hub-tls-failing` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

hub-bridge is not completing TLS handshakes on 8082, the port the hubs
connect to. If it is really broken, every hub is disconnected: no device
events, no commands, no alarms. Check the Active Sessions panel on the
overview dashboard first: if hubs are still connected, the probe is failing
for a reason the hubs do not share.

Known reasons the probe fails while hubs work:

- hub-bridge requires hub client certificates and aborts a TLS 1.2 handshake
  from a client without one (alert 40). The probe only passes over TLS 1.3,
  so `TLS_SERVER_CIPHERS` in `config/deployments/hub-bridge.yaml` must
  include TLS 1.3 suites. A release that reset the cipher list makes this
  alert fire with hubs unaffected.

## Confirm

```bash
kubectl get pods -l app=hub-bridge
./arcuscmd.sh logs hub-bridge | grep -iE 'keystore|ssl|tls|handshake' | tail -n 30
kubectl get secret hub-keystore
openssl s_client -connect hub.<domain>:8082 -tls1_3 </dev/null 2>&1 | grep -E 'Protocol|Verify|alert'
```

The probe's own view: `kubectl get --raw '/api/v1/namespaces/default/services/blackbox-exporter:9115/proxy/probe?module=tls_connect&target=hub-bridge-service:8082&debug=true'`.

## Fix

- **hub-bridge is down or restarting**: see [Service Down](service-down.md);
  the keystore errors in its log are the usual startup failure.
- **Keystore bad or missing**: `./arcuscmd.sh updatehubkeystore` recreates
  `hub-keystore` from `nginx-production-tls` (converting the key to PKCS#8)
  and restarts hub-bridge. This needs the production certificate, so run
  `./arcuscmd.sh useprodcert` first on a cluster still on staging.
- **Handshake failure with hubs connected**: the cipher list. Compare
  `TLS_SERVER_CIPHERS` in `config/deployments/hub-bridge.yaml` with master's
  and put the TLS 1.3 suites back.
- **Certificate expired**: [Hub Certificate Expiring](hub-cert-expiring.md)
  should have fired first; `./arcuscmd.sh updatehubkeystore` after the
  cert-manager certificate is renewed.

While 8082 is down, [Hub Certificate Expiring](hub-cert-expiring.md) has
nothing to read and is blind.

## Related alerts

- [Hub Certificate Expiring](hub-cert-expiring.md), [Hub Keystore Renewal Stale](keystore-renewal-stale.md).
- [Unexpected Hub Connections](unexpected-hubs.md) — hubs move between datacenters when one's 8082 fails.
