# Loki Discarding Logs

Severity **warning** · group Monitoring Health · fires as soon as Loki has refused log lines in the last 10 minutes.
Rule `loki-discarding-logs` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

Loki rejected lines Alloy sent. For `rate_limited` it refuses the whole push
with a 429 and Alloy retries it, so a short burst is often delivered late;
what Alloy gives up on fires [Log Shipping Dropping Entries](alloy-dropping-logs.md).
For the other reasons Loki stores the rest of the push and answers it with a
400, which Alloy doesn't retry, so the lines counted here are lost, except in
the replay under `too_far_behind`. The `reason` label says why:

- `rate_limited`: a pod is logging faster than `ingestion_rate_mb` /
  `ingestion_burst_size_mb` in `config/extrafiles/loki.yaml` allow.
- `line_too_long`: a line over `max_line_size`.
- `too_far_behind`: a line more than an hour older than the newest one Loki
  has for its stream. Almost always an Alloy pod that started without its
  positions and is reading every pod's log from the start: Loki accepts the
  last hour of it and refuses the older lines, which it already has.
  Nothing is lost, and the alert clears ten minutes after the replay. Alloy
  keeps its positions on the node in `/var/lib/arcus/alloy`, so this
  happens only when that directory is new or emptied: a new node, or the
  rollout that added it. Otherwise the node's clock has jumped.
- `greater_than_max_sample_age`: a line more than a week old.
- `stream_limit` / `max_label_names_per_series`: the Alloy pipeline in
  `config/logging/alloy.yaml` is producing too many streams or labels.

## Confirm

```bash
./arcuscmd.sh logs loki | grep -iE 'rate|limit|too (long|far)' | tail -n 20
kubectl get pod -l app=alloy   # too_far_behind: a pod about as old as the alert is a replay
```

The Log Volume by Service panel on the overview dashboard shows which
service is loud; Error Logs whether it is a service in trouble.

## Fix

- A service logging too much because something is wrong: fix the service
  (the logs say what), and the volume drops with it.
- A service that is just chatty: lower its level in
  `config/extrafiles/logback.xml`, or raise the limits in `loki.yaml`;
  `./arcuscmd.sh apply`.
- `too_far_behind` from a new Alloy pod: nothing to do. If it follows
  every Alloy rollout, the positions aren't surviving: `kubectl exec ds/alloy
  -- ls -lR /var/lib/alloy/data` should show
  `loki.source.kubernetes.pods/positions.yml` owned by 473, and the
  `data-owner` init container's log (`kubectl logs ds/alloy -c data-owner`)
  any failure to hand the directory over.
- Other timestamps, or `too_far_behind` with no new Alloy pod: the node's
  clock (`timedatectl`).
- Streams or labels: the pipeline change that introduced them in
  `config/logging/alloy.yaml`.

## Related alerts

- [Log Shipping Dropping Entries](alloy-dropping-logs.md), [Log Ingestion Stopped](log-ingestion-stopped.md).
