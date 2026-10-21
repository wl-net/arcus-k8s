# Certificate Renewal Overdue

Severity **warning** · group Service Health · fires when a cert-manager Certificate passed its renewal time more than 24 hours ago and has stayed that way for 15 minutes.
Rule `cert-renewal-overdue` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

cert-manager renews each certificate about 30 days before it expires. One
that is a day past its renewal time is stuck: the ACME order is failing, or
cert-manager is not running. Nothing is broken yet, so this is a working-hours
alert; it becomes [Certificate Expiring Soon](cert-expiring-soon.md) at 14 days.

## Confirm

```bash
kubectl describe certificate -n <namespace> <name>        # Status and Events
kubectl get certificaterequest,order,challenge -n <namespace>
./arcuscmd.sh certlogs
```

The Challenge is usually where it stops. Its description says why.

## Fix

- **HTTP-01 challenge failing** (`cert-solver` is `http`): Let's Encrypt must
  reach `http://<name>/.well-known/acme-challenge/` on port 80 at this
  cluster's public address. If the weighted Route 53 record points at another
  datacenter right now (drained), the challenge lands there and fails; it
  succeeds once traffic is back, or switch to the DNS solver.
  `./arcuscmd.sh check` and `./arcuscmd.sh info` show what is reachable.
- **DNS-01 challenge failing** (`cert-solver` is `dns`): the Route 53
  credentials in `secret/` or the hosted zone ID in `.config/` are wrong.
  `./arcuscmd.sh certlogs` has the AWS error.
- **Rate limited** by Let's Encrypt: wait for the window in the error. The
  staging issuer (`.config/cert-issuer`) has no limits for testing.
- **cert-manager not running**: `kubectl get pods -n cert-manager`, and
  `./arcuscmd.sh install cert-manager` to reinstall the pinned version.

Once the cause is fixed, `./arcuscmd.sh renewcert <name>` forces a new order
instead of waiting for cert-manager's retry.

## Related alerts

- [Certificate Expiring Soon](cert-expiring-soon.md) — the critical stage of the same problem.
- [Hub Certificate Expiring](hub-cert-expiring.md) — hub-bridge serves its own copy of the certificate.
