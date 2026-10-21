# Unexpected Hub Connections

Severity **critical** · group Service Health · fires when more hubs than `.config/expected-hubs` allows (default 4) have been connected for 5 minutes.
Rule `unexpected-hubs` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

hub-bridge reports more connected hubs than this datacenter should have. A
hub can only connect with a client certificate, so an extra one is either a
hub you forgot to count, a hub that normally lives at another datacenter
(the weighted record moved it here), or a hub that should not exist. Treat the
last as a security event until shown otherwise.

## Confirm

The Active Sessions and Hub Sessions (Detail) panels on the overview dashboard
show the count over time: a step when another datacenter drained is the
benign case.

```bash
./arcuscmd.sh logs hub-bridge | grep -iE 'hub (connected|registered|session)'   # hub IDs and source addresses
```

Compare the hub IDs with the ones you expect. On a Cassandra host, the
registration tells you which place a hub belongs to:

```bash
cqlsh -e "SELECT id, state, placeid, lastconnected FROM production.hub_registration"
```

## Fix

- A hub you expect: raise `.config/expected-hubs` and `./arcuscmd.sh apply`.
- A hub from another datacenter: it goes back when that datacenter resumes;
  nothing to do, or raise the threshold if this happens routinely.
- An unknown hub: its place and account tell you whose it is. Deregistering
  the hub from its place in the app drops its connection; to keep it out,
  revoke its certificate on the platform side, or block the source address
  at the router. Check the account for other changes
  ([Password Changed](password-changed.md), [Unauthorized Access Attempt](unauthorized-access.md)).

## Related alerts

- [Unauthorized Access Attempt](unauthorized-access.md), [Password Changed](password-changed.md) — the other security alerts.
