# Hub Keystore Renewal Stale

Severity **warning** · group Service Health · fires when the `hub-keystore-renewal` CronJob has not completed successfully for 13 hours.
Rule `keystore-renewal-stale` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

The CronJob runs every 6 hours to copy cert-manager's renewed certificate
(`nginx-production-tls`) into the `hub-keystore` Secret hub-bridge serves on
port 8082, and restart hub-bridge when it changed. Two runs have been missed.
Nothing is wrong yet: the certificate hub-bridge serves is still the one from
the last successful run, and it has weeks left unless this coincides with a
renewal. [Hub Certificate Expiring](hub-cert-expiring.md) fires if the copy
falls behind for real.

A hung run can't hold the others back for long: each run is stopped after
10 minutes (`activeDeadlineSeconds: 600`), which is there because
`concurrencyPolicy: Forbid` would otherwise queue every later run behind it.
So 13 hours without a success means the runs are failing (each one tries
twice, `backoffLimit: 1`), or the CronJob is suspended or missing.
[Job Failed](job-failed.md) fires for each failed run.

## Confirm

```bash
kubectl get cronjob hub-keystore-renewal
kubectl get jobs,pods | grep hub-keystore-renewal
kubectl logs job/<name>                   # the last run
```

## Fix

- A job that fails every time: its log says why. A missing
  `nginx-production-tls` Secret (the certificate was never issued in
  production, see `./arcuscmd.sh status`), or RBAC after an upgrade
  (`./arcuscmd.sh apply` reapplies the role).
- Jobs failing with `DeadlineExceeded` (`kubectl describe job <name>`): the
  run hit the 10 minute limit. A pod stuck ContainerCreating or
  ImagePullBackOff (the `alpine/openssl` or `alpine/k8s` image can't be
  pulled; `kubectl describe pod`), or hub-bridge's restart not finishing
  (see [Deployment Rollout Stuck](rollout-stuck.md)).
- The CronJob is suspended or missing: `kubectl get cronjob`;
  `./arcuscmd.sh apply` recreates it.

Then test a run without waiting:

```bash
kubectl create job --from=cronjob/hub-keystore-renewal hub-keystore-test
kubectl logs job/hub-keystore-test -f
kubectl delete job hub-keystore-test
```

`./arcuscmd.sh updatehubkeystore` does the same copy by hand if hub-bridge
needs the new certificate now.

## Related alerts

- [Hub Certificate Expiring](hub-cert-expiring.md) — the copy has fallen behind a renewal.
- [Job Failed](job-failed.md) — one failed run, with its log.
