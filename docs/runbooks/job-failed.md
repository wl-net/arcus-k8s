# Job Failed

Severity **warning** · group Service Health · fires when a Kubernetes Job started in the last 6 hours has used up its retries.
Rule `job-failed` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

A one-shot job failed. Which one matters:

- **modelmanager-\*** (started by `apply`, `deploy --version` or
  `./arcuscmd.sh modelmanager`): a Cassandra schema migration did not run.
  apply and deploy stop before changing any service when one fails, so the
  services are still on the release they were on; the new one waits for it.
- **hub-keystore-renewal-\***: one run of the CronJob failed. The hub
  certificate was not refreshed this time; [Hub Keystore Renewal Stale](keystore-renewal-stale.md)
  fires if that goes on, [Hub Certificate Expiring](hub-cert-expiring.md) if
  it matters.

## Confirm

```bash
kubectl get jobs -n <namespace>
kubectl describe job -n <namespace> <job>        # Events, and the pod names
kubectl logs job/<job> -n <namespace>            # the last attempt
```

## Fix

- modelmanager: the log is usually a Cassandra connection or authentication
  problem (`.config/cassandra-host`, the credentials in `secret/`), or a
  keyspace that does not exist yet. Fix it and run apply (or
  `deploy --version`) again, which runs the jobs before the services;
  `./arcuscmd.sh modelmanager` runs them on their own.
- hub-keystore-renewal: see [Hub Keystore Renewal Stale](keystore-renewal-stale.md);
  `kubectl create job --from=cronjob/hub-keystore-renewal hub-keystore-test`
  retries now.
- Anything else: the log.

The alert clears 6 hours after the failure, or sooner when the job is
deleted (`kubectl delete job <job>`).

## Related alerts

- [Hub Keystore Renewal Stale](keystore-renewal-stale.md), [Pod Crash Looping](pod-crash-looping.md).
