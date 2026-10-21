# Certificate Expiring Soon

Severity **critical** · group Service Health · fires when a cert-manager Certificate expires in less than 14 days (for 1 hour).
Rule `cert-expiring-soon` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

cert-manager should have renewed this certificate about 30 days before
expiry, so renewal has been failing for over two weeks. When it expires,
browsers, the mobile apps and the hubs stop connecting. Fix it today.

## Confirm

```bash
kubectl describe certificate -n <namespace> <name>
kubectl get certificaterequest,order,challenge -n <namespace>
./arcuscmd.sh certlogs
./arcuscmd.sh status                      # Certificates section
```

## Fix

Find the failing step as in [Certificate Renewal Overdue](cert-renewal-overdue.md),
fix it, then force a re-issue:

```bash
./arcuscmd.sh renewcert <name>
kubectl get certificate -n <namespace> <name> -w      # READY True with a new NOT AFTER
```

For `nginx-production-tls`, hub-bridge serves its own copy from the
`hub-keystore` Secret, which the `hub-keystore-renewal` CronJob refreshes
within 6 hours of the renewal. To do it at once:
`./arcuscmd.sh updatehubkeystore`. [Hub Certificate Expiring](hub-cert-expiring.md)
watches that copy.

If it cannot be fixed before expiry, drain this datacenter
(`./arcuscmd.sh drain`) so users and hubs go to one with a valid certificate.

## Related alerts

- [Certificate Renewal Overdue](cert-renewal-overdue.md) — the warning that came first.
- [Hub Certificate Expiring](hub-cert-expiring.md), [Hub TLS Failing](hub-tls-failing.md) — hub-bridge's copy.
- [Public Endpoint Unreachable](public-endpoint-unreachable.md) — fires once the certificate is invalid.
