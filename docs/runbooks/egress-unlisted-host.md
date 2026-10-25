# Egress To Unlisted Host

Severity **warning** · group Service Health · fires as soon as the egress proxy has forwarded a connection to a host that is not on its allowlist in the last 15 minutes.
Rule `egress-unlisted-host` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

notification-services reaches Twilio and Mailgun through the egress proxy
(`config/egress/egress-proxy.yaml`, an Envoy taking HTTPS CONNECT on
`egress-proxy:3128`). Its allowlist, the `listed` virtual host in
[`config/extrafiles/egress-proxy.yaml`](../../config/extrafiles/egress-proxy.yaml),
names the hosts we expect. Something just connected to a host that isn't
there.

For now the proxy still forwards unlisted hosts, so nothing has failed: the
alert is the warning that this call would fail once the proxy refuses them.
The usual causes are a provider moving its API to a new hostname, a feature
newly turned on (a different email provider, SmartyStreets, push), or a
client that shouldn't be calling out at all.

The alert names the host (`destination`) but not who called it; the log
line has the client's pod address.

## Confirm

In Grafana Explore (Loki):

```
{app="egress-proxy"} | logfmt | route="unlisted"
```

Each line has `destination`, `client` (the calling pod's IP), `code` and the
bytes each way. Then:

```bash
kubectl get pods -o wide | grep <client IP>
```

The Egress Destinations panel on the Arcus Cluster dashboard shows every
host the proxy has carried traffic to, listed or not.

## Fix

- An expected call (a provider's new hostname, a feature turned on on
  purpose): add `host:443` to the `listed` domains in
  `config/extrafiles/egress-proxy.yaml`, with a comment naming who calls it,
  `./arcuscmd.sh validate` (it runs `envoy --mode validate` on the file), then
  `./arcuscmd.sh apply`. The proxy pods restart with the new config one at a
  time.
- A call that shouldn't happen: find what makes it in the service's logs
  (`./arcuscmd.sh logs <app>`) and turn the feature off.

## Related alerts

- [Service Down](service-down.md) for `egress-proxy`: neither replica is
  ready, and notification-services can't send SMS, voice calls or email.
- [Email Notification Errors](notification-email-errors.md): what a refused
  Mailgun connection looks like from the sending side.
