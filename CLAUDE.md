# CLAUDE.md

## Project Overview

`arcus-k8s` is a Kubernetes deployment infrastructure project for [Arcus Smart Home](https://github.com/arcus-smart-home), an open-source home automation platform. It provides shell scripts and Kustomize manifests to deploy Arcus on local (k3s) or cloud Kubernetes clusters.

## Repository Layout

```
arcuscmd.sh                  # Main CLI — entry point for all operations
script/
  common.sh                  # Shared utilities (retry, prompts, APPS list, .config loading)
  funcs.sh                   # Sources the function modules below
  install.sh config.sh deploy.sh status.sh update.sh backup.sh
  route53.sh validate.sh grafana.sh node.sh notify.sh  # One module per command area
config/
  kustomization.yaml         # Root Kustomize manifest (image tags live here)
  configmaps/arcus-config.yaml # Global app config (domains, URLs, feature flags)
  configmaps/cluster-config.yaml # Datastore hosts (rewritten by apply from .config/)
  deployments/               # One YAML per microservice
  service/                   # Service and Ingress definitions
  stateful/                  # Prometheus, Loki & Grafana StatefulSets
  grafana/ dashboards/       # Grafana provisioning (datasources, alerting, dashboards)
  extrafiles/                # firmware.xml, logback.xml, Prometheus, Loki and blackbox exporter config
  logging/                   # Alloy log collector
  monitoring/                # kube-state-metrics (pod restarts, CrashLoopBackOff, OOM kills, ready replicas), blackbox exporter (TCP/TLS checks), node-exporter (disk space, CPU, memory)
  certprovider/              # Let's Encrypt issuers
  cronjob/                   # Scheduled jobs (hub-keystore renewal)
  jobs/                      # One-shot Kubernetes jobs
  templates/                 # Templates applied at runtime (MetalLB address pool)
overlays/
  local-production/          # Base overlay for single-node dev deployments
  local-production-cluster/  # Cluster-specific overrides
.github/workflows/ci.yml    # GitHub Actions CI (shellcheck + kustomize validation)
```

Secrets are written to `secret/` and local overlay state to `overlays/<overlay>-local/` — both are git-ignored.

## Key Technologies

| Layer | Tool / Version |
|---|---|
| Kubernetes distro | k3s v1.36.5+k3s1 (recommended) |
| Config management | Kustomize |
| Ingress | Traefik v3.7.13 (bundled with k3s) |
| Load balancer | MetalLB v0.16.1 (opt-in) |
| Certificates | cert-manager v1.21.2 + Let's Encrypt |
| Database | Apache Cassandra (external) |
| Messaging | Apache Kafka + Zookeeper (external) |
| Monitoring | Prometheus + Grafana (optional) |

## Common Commands

```bash
# Setup
./arcuscmd.sh setup          # Full first-time cluster init (interactive)
./arcuscmd.sh k3s            # Install or upgrade k3s
./arcuscmd.sh install        # Install/upgrade all infrastructure components
./arcuscmd.sh install traefik  # Install/upgrade a single component (metallb, traefik, cert-manager)
./arcuscmd.sh configure      # Interactive configuration wizard
./arcuscmd.sh shell-setup    # Add 'arcuscmd' shortcut to your shell

# Deploy
./arcuscmd.sh apply          # Deploy/update Arcus configuration
./arcuscmd.sh deploy         # Rolling restart of all services, one at a time
./arcuscmd.sh deploy --version 2026.10.3  # Move services to a release one at a time (or: deploy --version <tag> <svc...>)
./arcuscmd.sh update         # Pull latest changes, show what changed
./arcuscmd.sh rollback       # Revert to a previous version
./arcuscmd.sh history        # Show recent update history with apply status
./arcuscmd.sh useprodcert    # Switch from staging to production Let's Encrypt cert
./arcuscmd.sh renewcert      # Force re-issue of all certificates (or: renewcert <name>)
./arcuscmd.sh updatehubkeystore  # Convert PKCS#1 key to PKCS#8 for hub-bridge

# Status
./arcuscmd.sh status         # Show services, their builds, certificates, and infrastructure versions
./arcuscmd.sh versions       # Show installed vs configured infrastructure versions
./arcuscmd.sh info           # Show DNS to IP/port mappings
./arcuscmd.sh check          # Test public connectivity to Arcus services
./arcuscmd.sh verifyconfig   # Verify all configuration and secrets are present
./arcuscmd.sh validate       # YAML syntax, kustomize build, and kubeconform schema checks (same as CI)

# Operations
./arcuscmd.sh backupconfig   # Backup local configuration (.config, secrets, overlays) to a tarball
./arcuscmd.sh drain          # Set Route 53 weighted record to 0 (drain traffic from this cluster)
./arcuscmd.sh resume         # Restore Route 53 weighted record to its previous value
./arcuscmd.sh logs <app>     # Get logs for a service (targets running pods only)
./arcuscmd.sh shell <app>    # Get an interactive shell on a pod
./arcuscmd.sh modelmanager   # Run model manager jobs (provision database schemas)
./arcuscmd.sh deletepod <app>  # Delete pods matching an application
./arcuscmd.sh silence [2h]   # Silence Grafana alerts (unsilence to remove)
./arcuscmd.sh upgrade-node   # apt dist-upgrade this host
./arcuscmd.sh reboot-node    # Drain, silence alerts, disconnect bridges, reboot
./arcuscmd.sh help           # List all commands
```

## Making Changes

### Kubernetes manifests
- Edit files under `config/` for changes that apply to all environments.
- Put environment-specific overrides in `overlays/local-production/` (committed) or the `-local` copy (generated by `apply`, not committed).
- Run `./arcuscmd.sh apply` to deploy. The overlay tunable files (`arcus-config-tunable.yaml`, `cluster-config-tunable.yaml`) are preserved across apply runs.

### Image versions
- Image tags are centrally managed in `config/kustomization.yaml`.
- When `apply` changes the tags it updates every service at once. `./arcuscmd.sh deploy --version <tag>` moves services one at a time instead (it pulls the tag first, so one that doesn't exist changes nothing). A tag ahead of `config/kustomization.yaml` is recorded in `.config/image-version/<service>`, and `apply` keeps the service on it until `config/kustomization.yaml` reaches that version, then drops the record. A tag behind it lasts until the next `apply`. `status` lists the services held ahead.

### Secrets
- Secrets are generated once by `configure` and stored in `secret/`. Re-running configure will not overwrite existing secrets.
- Secrets are pushed to the cluster by `apply` (not `configure`).
- Never commit the `secret/` directory.
- Run `./arcuscmd.sh verifyconfig` to check all required secrets are present.

### Adding a new microservice
1. Add a deployment manifest in `config/deployments/`.
2. Add a service manifest in `config/service/` if network access is needed.
3. Reference both in `config/kustomization.yaml` under `resources`.
4. Add any required config keys to `config/configmaps/arcus-config.yaml`.
5. Add readiness and liveness probes (TCP socket on the metrics port).
6. Set resource requests and limits. For JVM services keep the memory limit well above `-Xmx`: the existing services run at roughly 3× their `-Xmx` in total (e.g. 128m heap, ~390Mi working set).

## Infrastructure Notes

- The project targets **k3s** as the recommended Kubernetes distribution.
- `./arcuscmd.sh k3s` writes `/etc/rancher/k3s/config.yaml.d/arcus-image-gc.yaml`, so the kubelet deletes unused images once the disk passes 75% (clearing down to 65%) instead of its default 85%. That's below the Node Disk Filling alert's 80%, so old release images no longer set it off. A node picks this up the next time `./arcuscmd.sh k3s` runs (which restarts k3s; running containers keep going).
- MetalLB is opt-in (enable via `./arcuscmd.sh configure` or write `yes` to `.config/metallb`). When enabled, it provides LoadBalancer IPs using the address pool template in `config/templates/metallb.yaml`. Configure the subnet to a static range excluded from your DHCP scope.
- cert-manager handles Let's Encrypt certificates. Start with the staging issuer and switch to production via `./arcuscmd.sh useprodcert` once DNS is verified.
- Hub-bridge requires PKCS#8 keys; run `./arcuscmd.sh updatehubkeystore` after obtaining a production certificate. A CronJob (`hub-keystore-renewal`) runs every 6 hours to automatically detect cert-manager renewals of `nginx-production-tls` and recreate the `hub-keystore` secret + restart hub-bridge. It uses an `arcus.io/source-resource-version` annotation for idempotency. To test manually: `kubectl create job --from=cronjob/hub-keystore-renewal hub-keystore-test`. Grafana alerts if the CronJob hasn't succeeded in 13 hours, if hub-bridge stops completing TLS handshakes on 8082, or if the certificate it serves there is within 21 days of expiry (the blackbox exporter probes 8082 directly, so this catches a keystore that missed a renewal whatever the cause).
- Alert notification text comes from the `arcus` notification template at the end of `config/grafana/alerting.yaml`. The Discord and Pushover contact points aren't provisioned; each datacenter's Grafana has them set up by hand, with Title `{{ template "arcus.title" . }}` and Message `{{ template "arcus.message" . }}` (Discord) or `{{ template "arcus.text" . }}` (Pushover). Grafana exits at startup if a provisioned template fails to parse (e.g. an undefined function: `humanizeDuration` isn't available), so render changes with the template test API before deploying.

## Per-Node Configuration (`.config/`)

Each node stores its local configuration in `.config/` (git-ignored). These files are read by `load()` at startup and written by `./arcuscmd.sh configure`.

| File | Required | Description |
|---|---|---|
| `domain.name` | Yes | Main Arcus domain (e.g. `arcus.example.com`) |
| `admin.email` | Yes | Let's Encrypt admin email |
| `cert-issuer` | Yes | `staging` or `production` |
| `overlay-name` | Yes | Kustomize overlay to use (e.g. `local-production-cluster`) |
| `metallb` | Optional | `yes` or `no` — enable MetalLB for load balancer IPs |
| `subnet` | If MetalLB | MetalLB IP range (e.g. `192.168.1.200-192.168.1.207`) |
| `proxy-real-ip` | Optional | Upstream proxy IP/subnet for PROXY protocol (e.g. `192.168.1.1/32`) |
| `cassandra-host` | Yes | Cassandra contact points, comma-separated (e.g. `10.0.0.10,10.0.0.11`) |
| `zookeeper-host` | Yes | ZooKeeper `host:port` (e.g. `10.0.0.30:2181`) |
| `kafka-host` | Yes | Kafka bootstrap server `host:port` (e.g. `10.0.0.20:9092`) |
| `admin-domain` | Optional | Grafana admin domain (e.g. `admin.arcus-dc1.example.com`) |
| `peer-admin-domains` | Optional | Admin domains of the other datacenters, comma-separated (e.g. `admin.arcus-dc2.example.com`); this node alerts when their Grafana stops answering |
| `cert-solver` | Optional | `http` (default) or `dns` — use DNS-01 challenges via Route 53 |
| `route53-hosted-zone-id` | If DNS solver | Route 53 hosted zone ID |
| `route53-region` | If DNS solver | AWS region for Route 53 (e.g. `us-east-1`) |
| `route53-set-identifier` | Optional | Route 53 set identifier for weighted record (used by `drain`/`resume`) |
| `discord-webhook` | Optional | Discord webhook URL for notifications on state-changing commands |
| `discord-silent` | Optional | If present, suppresses Discord notifications (`notify-off`/`notify-on`) |
| `image-version/<service>` | Written by `deploy --version` | Image tag a service was moved to ahead of `config/kustomization.yaml`; removed by `apply` once the configured tag catches up |

Run `./arcuscmd.sh configure` to set these interactively, or write the files directly.

## Cassandra / Kafka / Zookeeper

Cassandra, Kafka and Zookeeper always run outside the cluster (production uses a dedicated 3-datacenter Cassandra cluster); this repo has no in-cluster copies. `.config/cassandra-host`, `.config/kafka-host` and `.config/zookeeper-host` are required: `configure` asks for them, and `apply` stops if one is missing. `apply` writes them into the generated `cluster-config.yaml` in place of the `PLACEHOLDER_*` hosts in `config/configmaps/cluster-config.yaml`; both overlays apply that file. A node's `-local` `cluster-config-tunable.yaml` is applied after it, so any host keys left in that file override `.config/`. `apply` also writes every host to the `prometheus-targets` ConfigMap, and the blackbox exporter checks each one accepts TCP connections (the Datastore Unreachable alert); ports default to 9042, 9092 and 2181. With `.config/peer-admin-domains` set, it also writes the other datacenters' Grafana health endpoints (`https://<admin domain>/api/health`) there, so each datacenter alerts when another one, or its monitoring, stops answering (the Peer Datacenter Unreachable alert).

## External Service Dependencies

Arcus requires accounts with:
- **SmartyStreets** — address verification (required for account creation)
- **Twilio** — SMS/voice notifications
- **Sendgrid / Mailgun** — email notifications
- **APNS / GCM** — push notifications (optional, disabled by default)

## Backups

```bash
./arcuscmd.sh backupconfig   # Creates a timestamped tarball of .config, secrets, and local overlays
```

Cassandra is the only stateful component that needs backup. It runs outside the cluster, so back it up where it runs; this repo doesn't manage it.

## CI

GitHub Actions runs on push and PRs to master:
- **shellcheck** — lints `arcuscmd.sh` and `script/*.sh` with a pinned shellcheck (0.11.0) at the default `style` severity; run `shellcheck -x arcuscmd.sh script/*.sh` locally
- **cli** — smoke tests: `help` works without kubectl, kubectl-dependent commands fail early without it, the root guard, and unknown subcommands exit non-zero
- **manifests** — `./arcuscmd.sh validate`: YAML syntax for `config/` and `overlays/`, `config/` kustomize build, and kubeconform schemas for the Kubernetes version in `K3S_VERSION`. The overlays aren't built, since they need files `apply` generates.

## Hardware Requirements

- 12 GB RAM minimum
- 20 GB disk minimum
- Public IP with ports 80/443 reachable for Let's Encrypt and mobile app support
