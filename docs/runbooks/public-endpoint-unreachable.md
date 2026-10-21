# Public Endpoint Unreachable

Severity **critical** · group Service Health · fires when one of this cluster's public URLs has failed its check for 5 minutes.
Rule `public-endpoint-unreachable` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

The blackbox exporter resolves the public name through public DNS and
connects the way a user or hub would. It failed: the name does not resolve
to a working address, the port is closed, TLS fails (expired or wrong
certificate), or the answer is not a 2xx/3xx. The in-cluster services may
be fine; the path to them is not.

A drained cluster passes this check, because the name then points at the
other datacenter. So when this fires, users on this datacenter's record are
failing right now.

## Confirm

```bash
./arcuscmd.sh check                       # the same checks, from here
./arcuscmd.sh info                        # what the names should resolve to
dig +short <name>                         # from outside the LAN if you can
curl -vk https://<name>/ 2>&1 | grep -E 'Connected|SSL|HTTP/'
kubectl get ingress; kubectl get svc traefik -n kube-system
```

## Fix

By where it stops:

- **DNS**: the Route 53 record (weighted, with `route53-set-identifier`) or
  the public IP changed. Dynamic DNS or the health check in the AWS console.
- **Connection refused / timeout**: port forwarding 80/443 on the router to
  the Traefik LoadBalancer IP (`kubectl get svc -n kube-system traefik`;
  with MetalLB, the pool in `.config/subnet`). `./arcuscmd.sh install traefik`
  reinstalls Traefik if it is gone.
- **TLS**: the certificate. `./arcuscmd.sh status` shows it; a staging
  certificate on a production cluster needs `./arcuscmd.sh useprodcert`;
  an expired one, [Certificate Expiring Soon](cert-expiring-soon.md).
- **HTTP 404 / 502 / 503**: Traefik is up but the Ingress or the service
  behind it is not. `kubectl get ingress`, and [Service Down](service-down.md)
  for ui-server, client-bridge or static.

If it cannot be fixed quickly, `./arcuscmd.sh drain` moves users and hubs to
the other datacenter; `./arcuscmd.sh resume` when it is back.

## Related alerts

- [Certificate Expiring Soon](cert-expiring-soon.md), [Service Down](service-down.md).
- [Peer Datacenter Unreachable](peer-datacenter-unreachable.md) — the same check, run by the other datacenters.
