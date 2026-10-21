# Loki Discarding Logs

Severity **warning** · group Monitoring Health · fires as soon as Loki has refused log lines in the last 10 minutes.
Rule `loki-discarding-logs` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

Loki rejected lines Alloy sent. The `reason` label says why:

- `rate_limited`: a pod is logging faster than `ingestion_rate_mb` /
  `ingestion_burst_size_mb` in `config/extrafiles/loki.yaml` allow.
- `line_too_long`: a line over `max_line_size`.
- `too_far_behind` / `greater_than_max_sample_age`: a timestamp Loki will
  not accept, usually a pod's log file being re-read after a restart.
- `stream_limit` / `max_label_names_per_series`: the Alloy pipeline in
  `config/logging/alloy.yaml` is producing too many streams or labels.

Alloy retries rate-limited pushes, so a short burst is often delivered
late; what Alloy gives up on fires [Log Shipping Dropping Entries](alloy-dropping-logs.md).

## Confirm

```bash
./arcuscmd.sh logs loki | grep -iE 'rate|limit|too (long|far)' | tail -n 20
```

The Log Volume by Service panel on the overview dashboard shows which
service is loud; Error Logs whether it is a service in trouble.

## Fix

- A service logging too much because something is wrong: fix the service
  (the logs say what), and the volume drops with it.
- A service that is just chatty: lower its level in
  `config/extrafiles/logback.xml`, or raise the limits in `loki.yaml`;
  `./arcuscmd.sh apply`.
- Timestamps: harmless after a restart; if constant, the node's clock.
- Streams or labels: the pipeline change that introduced them in
  `config/logging/alloy.yaml`.

## Related alerts

- [Log Shipping Dropping Entries](alloy-dropping-logs.md), [Log Ingestion Stopped](log-ingestion-stopped.md).
