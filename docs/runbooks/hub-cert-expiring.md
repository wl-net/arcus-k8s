# Hub Certificate Expiring

Severity **critical** · group Service Health · fires when the certificate hub-bridge serves on port 8082 expires in less than 21 days (for 1 hour).
Rule `hub-cert-expiring` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

hub-bridge serves its own copy of the certificate, from the `hub-keystore`
Secret. cert-manager renews the real one about 30 days before expiry and the
`hub-keystore-renewal` CronJob copies it within 6 hours, so a copy this close
to expiry has missed a renewal. When it expires the hubs stop connecting.

Either cert-manager has not renewed (then [Certificate Expiring Soon](cert-expiring-soon.md)
fires too), or it has and the copy did not follow.

## Confirm

```bash
./arcuscmd.sh status                      # Certificates: the cert-manager one and its expiry
kubectl get secret nginx-production-tls -o jsonpath='{.metadata.resourceVersion}'; echo
kubectl get secret hub-keystore -o jsonpath='{.metadata.annotations.arcus\.io/source-resource-version}'; echo
kubectl get jobs | grep hub-keystore-renewal
```

Matching resource versions mean the copy is current and the real
certificate is the old one. Different ones mean the CronJob has not copied
the renewed certificate.

## Fix

- cert-manager has not renewed: fix that first, see
  [Certificate Expiring Soon](cert-expiring-soon.md).
- cert-manager renewed, copy stale: `./arcuscmd.sh updatehubkeystore` copies it
  now and restarts hub-bridge (hubs reconnect within a minute). Then find out
  why the CronJob did not: [Hub Keystore Renewal Stale](keystore-renewal-stale.md).

Check afterwards: `openssl s_client -connect hub.<domain>:8082 -tls1_3 </dev/null 2>/dev/null | openssl x509 -noout -dates`.

## Related alerts

- [Certificate Expiring Soon](cert-expiring-soon.md), [Hub Keystore Renewal Stale](keystore-renewal-stale.md), [Hub TLS Failing](hub-tls-failing.md).
