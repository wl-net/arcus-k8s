# CLAUDE.md

## Project Overview

`arcus-k8s` is a Kubernetes deployment infrastructure project for [Arcus Smart Home](https://github.com/arcus-smart-home), an open-source home automation platform. It provides shell scripts and Kustomize manifests to deploy Arcus on local (k3s) or cloud Kubernetes clusters.

## Repository Layout

```
arcuscmd.sh                  # Main CLI — entry point for all operations
script/
  funcs.sh                   # Core deployment functions (~1600 lines)
  common.sh                  # Shared utilities (retry, prompts, status checks)
  shared-secret.sh           # Secret generation
  shared-config.sh           # Config generation
  gcloud.sh                  # Google Cloud helpers
config/
  kustomization.yaml         # Root Kustomize manifest (image tags live here)
  configmaps/arcus-config.yml  # Global app config (domains, Cassandra, Kafka)
  deployments/               # One YAML per microservice
  service/                   # Service and Ingress definitions
  stateful/                  # Prometheus & Grafana StatefulSets
  certprovider/              # Let's Encrypt issuers
  jobs/                      # One-shot Kubernetes jobs
  istio/                     # Egress rules
overlays/
  local-production/          # Base overlay (edit domain, email, cert provider here)
  local-production-cluster/  # Cluster-specific overrides (git-ignored local copy)
localk8s/                    # MetalLB and TCP service config
```

Secrets are written to `secret/` and local overlay state to `overlays/local-production-local/` — both are git-ignored.

## Key Technologies

| Layer | Tool / Version |
|---|---|
| Kubernetes distro | k3s v1.26.0 (recommended) |
| Config management | Kustomize |
| Service mesh | Istio v1.26.0 |
| Ingress | nginx-ingress v1.12.2 |
| Load balancer | MetalLB v0.14.9 |
| Certificates | cert-manager v1.17.2 + Let's Encrypt |
| Database | Apache Cassandra |
| Messaging | Apache Kafka + Zookeeper |
| Monitoring | Prometheus + Grafana (optional) |

## Common Commands

```bash
./arcuscmd.sh setup          # Full first-time cluster init (interactive)
./arcuscmd.sh install        # Install/upgrade Kubernetes components
./arcuscmd.sh apply          # Deploy/update Arcus configuration
./arcuscmd.sh deploy         # Rolling update with minimal downtime
./arcuscmd.sh configure      # Interactive configuration wizard
./arcuscmd.sh provision      # Initialize Cassandra/Kafka
./arcuscmd.sh useprodcert    # Switch from staging to production Let's Encrypt cert
./arcuscmd.sh updatehubkeystore  # Convert PKCS#1 key to PKCS#8 for hub-bridge
./arcuscmd.sh info           # Show DNS → IP/port mappings
./arcuscmd.sh logs           # Tail service logs
./arcuscmd.sh dbshell        # Open Cassandra CQL shell
./arcuscmd.sh update         # git pull + apply
./arcuscmd.sh help           # List all commands
```

## Making Changes

### Kubernetes manifests
- Edit files under `config/` for changes that apply to all environments.
- Put environment-specific overrides in `overlays/local-production/` (committed) or `overlays/local-production-local/` (local only, not committed).
- Use `kustomize build overlays/local-production-cluster | kubectl apply -f -` to preview what will be applied, or just run `./arcuscmd.sh apply`.

### Image versions
- Image tags are centrally managed in `config/kustomization.yaml`.

### Secrets
- Secrets are generated once and stored in `secret/`. Re-running setup will not overwrite existing secrets.
- Never commit the `secret/` directory.

### Adding a new microservice
1. Add a deployment manifest in `config/deployments/`.
2. Add a service manifest in `config/service/` if network access is needed.
3. Reference both in `config/kustomization.yaml` under `resources`.
4. Add any required config keys to `config/configmaps/arcus-config.yml`.

## Infrastructure Notes

- The project targets **k3s** as the recommended Kubernetes distribution. microk8s is deprecated.
- MetalLB provides LoadBalancer IPs for bare-metal/local clusters. Configure the address pool in `localk8s/metallb.yml` to match a static range excluded from your DHCP scope.
- Istio egress rules in `config/istio/` control outbound traffic to external APIs (Twilio, Sendgrid, SmartyStreets, etc.).
- cert-manager handles Let's Encrypt certificates. Start with the staging issuer in `config/certprovider/` and switch to production via `./arcuscmd.sh useprodcert` once DNS is verified.
- Hub-bridge requires PKCS#8 keys; run `./arcuscmd.sh updatehubkeystore` after obtaining a production certificate.

## External Service Dependencies

Arcus requires accounts with:
- **SmartyStreets** — address verification (required for account creation)
- **Twilio** — SMS/voice notifications
- **Sendgrid / Mailgun** — email notifications
- **APNS / GCM** — push notifications (optional, disabled by default)

## Backups

Cassandra is the only stateful component that needs backup. Use the provided scripts:

```bash
./backup-cassandra-snapshot.sh
./restore-cassandra-snapshot.sh
```

## Hardware Requirements

- 12 GB RAM minimum
- 20 GB disk minimum
- Public IP with ports 80/443 reachable for Let's Encrypt and mobile app support
