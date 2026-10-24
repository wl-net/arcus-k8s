# Alert runbooks

One page per rule in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml),
named after the rule's `uid`. Each says what the alert means, how to confirm
it, how to fix it, and which alerts are related. The rule's `runbook_url`
annotation points here, so a notification carries a Runbook link next to
Rule, Panel and Silence, and the alert's page in Grafana has a Runbook
button. `./arcuscmd.sh validate` fails when a rule has no runbook or a
runbook has no rule.

## When an alert arrives

Severity says how fast to act:

- **critical** — users or hubs are affected now, or will be without action
  today. Paged to Pushover as well as Discord.
- **warning** — needs attention in working hours.
- **info** — for the record.

The notification links to the rule (its query and current state), the panel
the rule reads from (with the alert's state changes drawn on it), the
runbook, and a one-click silence. The Alerts panel at the top of the
Arcus Overview dashboard shows everything firing or pending right now, and
Alerting → History in Grafana shows every state change of the last 30 days
(kept in Loki, so it can be queried next to the logs with
`{from="state-history"}`). The Runbook link names the commit the datacenter
runs, so it matches the rule that fired even after a rollback.

An alert named **DatasourceError** with `rulename = Monitoring Service Down`
means Prometheus itself has not answered Grafana for 5 minutes; see
[Monitoring Service Down](monitoring-service-down.md). No other rule raises
one: they keep their last state through an evaluation error, so Loki or
Prometheus restarting during `apply` does not page.

To quieten everything during planned work: `./arcuscmd.sh silence 2h`
(`unsilence` to lift it). `./arcuscmd.sh reboot-node` silences on its own.

## Writing one

Copy the shape of an existing page: the title is the rule's `title`, the
line under it gives the severity, group and when it fires, and the four
sections are `What it means`, `Confirm`, `Fix` and `Related alerts`
(validate checks for them). Keep the rule's `description` to the meaning
and the first command; the procedure lives here. Commands should be ones
that work on any datacenter from `./arcuscmd.sh` or `kubectl`; name the
node or pod with the alert's labels where the description does.

## Index

### Node Health

| Alert | Severity | Fires |
|---|---|---|
| [Node Disk Filling](node-disk-filling.md) | warning | Fires when a filesystem has been more than 80% full for 30 minutes |
| [Node Disk Critical](node-disk-critical.md) | critical | Fires when a filesystem has been more than 90% full for 5 minutes |
| [Node Memory Low](node-memory-low.md) | critical | Fires when less than 10% of the node's memory has been available for 10 minutes |
| [Node CPU Saturated](node-cpu-saturated.md) | warning | Fires when runnable processes on the node have been waiting for a CPU more than 25% of the time for 15 minutes |
| [Node Swapping](node-swapping.md) | warning | Fires when the node has been moving more than 1 MiB/s to and from swap for 15 minutes |
| [Node Not Ready](node-not-ready.md) | critical | Fires when a node has not reported Ready for 5 minutes |
| [Node Under Pressure](node-pressure.md) | critical | Fires when a node has reported MemoryPressure, DiskPressure or PIDPressure for 5 minutes |

### Service Health

| Alert | Severity | Fires |
|---|---|---|
| [Service Down](service-down.md) | critical | Fires when Prometheus has not been able to scrape any ready pod of a service, or the blackbox exporter, for 5 minutes. Also fires on no data |
| [Pod Crash Looping](pod-crash-looping.md) | critical | Fires when a container has been in CrashLoopBackOff for 10 minutes |
| [Container OOM Killed](container-oom-killed.md) | warning | Fires as soon as a container restarts after an OOMKilled exit |
| [Image Pull Failing](image-pull-failing.md) | warning | Fires when a container has been in ErrImagePull, ImagePullBackOff or InvalidImageName for 10 minutes |
| [Workload Unavailable](workload-unavailable.md) | critical | Fires when a Deployment, StatefulSet or DaemonSet has had fewer ready pods than it wants for 10 minutes |
| [Certificate Renewal Overdue](cert-renewal-overdue.md) | warning | Fires when a cert-manager Certificate passed its renewal time more than 24 hours ago and has stayed that way for 15 minutes |
| [Certificate Expiring Soon](cert-expiring-soon.md) | critical | Fires when a cert-manager Certificate expires in less than 14 days (for 1 hour) |
| [Unexpected Hub Connections](unexpected-hubs.md) | critical | Fires when more hubs than `.config/expected-hubs` allows (default 4) have been connected for 5 minutes |
| [Password Changed](password-changed.md) | warning | Fires as soon as the platform processes a person's password change |
| [Unauthorized Access Attempt](unauthorized-access.md) | warning | Fires as soon as a bridge rejects a request for a place, person or support role the session is not allowed to use |
| [Login Failures Elevated](login-failures-elevated.md) | warning | Fires when password logins have failed with unknown accounts or bad credentials more than 10 times in 15 minutes, for 5 minutes |
| [PIN Verification Failures](pin-verify-failures.md) | warning | Fires when place PIN checks have mismatched more than 5 times in 15 minutes |
| [Hub Authorization Violations](hub-authz-violations.md) | warning | Fires as soon as hub-bridge refuses a hub message for a source, place or authorization violation |
| [Hub Certificate Rejected](hub-cert-rejections.md) | warning | Fires as soon as hub-bridge rejects a hub TLS handshake over its certificate |
| [Email Notification Errors](notification-email-errors.md) | warning | Fires when notification-services has failed to send email for 5 minutes |
| [Scheduler Errors](scheduler-errors.md) | warning | Fires when scheduler-service has been failing scheduled commands for 5 minutes |
| [Datastore Unreachable](datastore-unreachable.md) | critical | Fires when the blackbox exporter has not been able to open a TCP connection to a Cassandra, Kafka or ZooKeeper host for 2 minutes |
| [ZooKeeper Session Expired](zookeeper-session-expired.md) | critical | Fires as soon as a service has logged that its ZooKeeper session expired in the last 10 minutes |
| [Hub Keystore Renewal Stale](keystore-renewal-stale.md) | warning | Fires when the `hub-keystore-renewal` CronJob has not completed successfully for 13 hours |
| [Hub TLS Failing](hub-tls-failing.md) | critical | Fires when the blackbox exporter has not been able to complete a TLS handshake with hub-bridge on port 8082 for 5 minutes |
| [Hub Certificate Expiring](hub-cert-expiring.md) | critical | Fires when the certificate hub-bridge serves on port 8082 expires in less than 21 days (for 1 hour) |
| [Hub Firmware Upgrade Stuck](hub-firmware-upgrade-stuck.md) | warning | Fires when hub-bridge has logged more than 2 firmware upgrade failures for one hub in 6 hours, with failures both in the last 2 hours and 4 to 6 hours ago |
| [Session Churn High](session-churn-high.md) | warning | Fires when a bridge has closed more than 15 sessions younger than 60 seconds in 15 minutes, for 5 minutes |
| [Hub Heartbeats Stale](hub-heartbeats-stale.md) | warning | Fires when an online hub has gone more than 2 minutes without a heartbeat, for 10 minutes |
| [Alloy Inotify Errors](alloy-inotify-errors.md) | warning | Fires when Alloy has logged "too many open files" in the last 5 minutes, for 2 minutes |
| [Log Ingestion Stopped](log-ingestion-stopped.md) | warning | Fires when Loki has received no log lines from any pod for 15 minutes (for 5 minutes) |
| [Peer Datacenter Unreachable](peer-datacenter-unreachable.md) | critical | Fires when a check of another datacenter has failed for 5 minutes |
| [Monitoring Service Down](monitoring-service-down.md) | warning | Fires when Prometheus has not been able to scrape one of the monitoring components for 5 minutes. Also fires on no data |
| [Pod Stuck Pending](pod-pending.md) | warning | Fires when a pod has been Pending for 10 minutes for a reason other than an image pull |
| [Deployment Rollout Stuck](rollout-stuck.md) | warning | Fires when a Deployment has reported Progressing=False for 5 minutes |
| [Job Failed](job-failed.md) | warning | Fires when a Kubernetes Job started in the last 6 hours has used up its retries |
| [Public Endpoint Unreachable](public-endpoint-unreachable.md) | critical | Fires when one of this cluster's public URLs has failed its check for 5 minutes |

### Monitoring Health

| Alert | Severity | Fires |
|---|---|---|
| [Alert Notifications Failing](grafana-notifications-failing.md) | critical | Fires as soon as a Grafana contact point has failed to deliver in the last 15 minutes |
| [Prometheus Storage Errors](prometheus-storage-errors.md) | warning | Fires as soon as Prometheus has failed a compaction or found a corrupt WAL segment in the last 2 hours |
| [Log Shipping Dropping Entries](alloy-dropping-logs.md) | warning | Fires as soon as Alloy has given up on log entries in the last 10 minutes |
| [Loki Discarding Logs](loki-discarding-logs.md) | warning | Fires as soon as Loki has refused log lines in the last 10 minutes |
| [Log Flood](log-flood.md) | warning | Fires as soon as a service has averaged more than 60000 log lines a minute over the last 5 minutes |
