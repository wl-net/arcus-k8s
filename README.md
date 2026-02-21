# arcus-k8s

[![CI](https://github.com/wl-net/arcus-k8s/actions/workflows/ci.yml/badge.svg)](https://github.com/wl-net/arcus-k8s/actions/workflows/ci.yml)

Kubernetes deployment infrastructure for [Arcus Smart Home](https://github.com/arcus-smart-home). Provides shell scripts and Kustomize manifests to deploy Arcus on local (k3s) or cloud Kubernetes clusters.

# Quickstart

```bash
# Local deployment (k3s)
./arcuscmd.sh setup              # Interactive first-time setup (installs k3s, configures, deploys)

# Or step by step / cloud deployment
./arcuscmd.sh k3s                # Install k3s (skip for cloud)
./arcuscmd.sh install            # Install infrastructure (nginx-ingress, cert-manager, istio)
./arcuscmd.sh configure          # Configure domain, secrets, and external services
./arcuscmd.sh apply              # Deploy Arcus to the cluster
./arcuscmd.sh modelmanager       # Provision database schemas (first time only)

# Day-to-day
./arcuscmd.sh update             # Pull latest changes and see what changed
./arcuscmd.sh apply              # Deploy updated configuration
./arcuscmd.sh deploy             # Rolling restart of services
./arcuscmd.sh status             # Show services, certs, and infrastructure versions
./arcuscmd.sh help               # List all commands
```

# Prerequisites

You either need access to a Kubernetes environment, or suitable bare metal to run one on. You should have 12GB or more of RAM, and at least 20GB of disk space. In order to obtain browser-trusted certificates, you will need to have Arcus publicly accessible, on a well known port (80/443). Using self-signed certificates is not recommended, and will not be supported by the iOS or Android applications (outside of modifying the trust store yourself).

In order to create an account, you will need to have a SmartyStreets account (for address verification).

For notifications, you must create a Twilio and Sendgrid account. APNS and GCM support is disabled by default and must be configured if desired. Typically this also requires that you distribute and side-load the app onto your device.

# Keeping Up to Date

Only the latest version of this project is supported. To stay current:

1. **Pull changes:** `./arcuscmd.sh update`
2. **Upgrade infrastructure** (nginx-ingress, cert-manager, istio): `./arcuscmd.sh install`
3. **Apply configuration:** `./arcuscmd.sh apply`
4. **Restart services** to pick up new images: `./arcuscmd.sh deploy`

It is recommended to do this at least weekly. Running `install` and `apply` together ensures infrastructure components and Arcus configuration stay in sync.

# Run locally (k3s) - Recommended

[k3s by rancher](https://k3s.io/) is the recommended means of installing Kubernetes, as it's more trimmed down and allows this project to use more modern versions of Kubernetes projects, like Istio.

Simply execute:

`./arcuscmd.sh setup`

and choose "local" and then "k3s"

## Configuring networking

In order to access the Arcus UI and connect a hub, you will need to configure your network. You have some options when it comes to this. If you are operating in a home environment (e.g. you have NAT and you're behind a gateway), then you have Arcus run a "LoadBalancer" on your local network. For this configuration, you will need to exclude a region of your network from DHCP. For example, if you are using the 192.168.1.1/24 subnet, then you should configure DHCP to assign addresses between 192.168.1.2-192.168.1.150, and use 192.168.151-192.168.155 for Arcus.

Once you have configured this, and Arcus is running you should check to see which IP addresses in that space are actually being used. You can either do this via kubectl, or with the `info` utility in arcuscmd.

```
$ ./arcuscmd.sh info
DNS -> IP/Port Mappings: 
If these IP addresses are private, you are responsible for setting up port forwarding

dev.arcus.wl-net.net:80           -> 172.16.6.4:80
dev.arcus.wl-net.net:443          -> 172.16.6.4:443
client.dev.arcus.wl-net.net:443   -> 172.16.6.4:443
static.dev.arcus.wl-net.net:443   -> 172.16.6.4:443
ipcd.dev.arcus.wl-net.net:443     -> 172.16.6.4:443
admin.dev.arcus.wl-net.net:443    -> 172.16.6.4:443
hub.dev.arcus.wl-net.net:443      -> 172.16.6.4:443 OR 172.16.6.2:8082
```

Alternatively: 

```
$ kubectl get service
NAME                    TYPE           CLUSTER-IP       EXTERNAL-IP   PORT(S)                                                                      AGE
cassandra-service       NodePort       10.152.183.225   <none>        7000:31287/TCP,7001:31914/TCP,7199:32251/TCP,9042:32178/TCP,9160:31262/TCP   27h
client-bridge-service   NodePort       10.152.183.68    <none>        80:31803/TCP                                                                 27h
hub-bridge-service      LoadBalancer   10.152.183.14    172.16.6.1    8082:31804/TCP                                                               6h1m
kafka-service           NodePort       10.152.183.250   <none>        9092:30997/TCP                                                               27h
kubernetes              ClusterIP      10.152.183.1     <none>        443/TCP                                                                      27h
ui-server-service       NodePort       10.152.183.88    <none>        80:30787/TCP                                                                 27h
zookeeper-service       NodePort       10.152.183.132   <none>        2181:30849/TCP                                                               27h
```

This shows that 172.16.6.1 is the IP address of our hub-bridge service (listening on port 8082).

```
$ kubectl get service -n ingress-nginx
NAME            TYPE           CLUSTER-IP       EXTERNAL-IP   PORT(S)                      AGE
ingress-nginx   LoadBalancer   10.152.183.146   172.16.6.0    80:31535/TCP,443:32684/TCP   27h
```

This shows that 172.16.6.0 is the IP address of the ui-service and client-bridge services (via nginx proxy). 

It's beyond the scope of this document to describe how to configure your network, but at a high level you will need to forward traffic to these ports (e.g. port forwarding).

Example (note, you must replace GATEWAY_IP accordingly):

```
iptables -t nat -A PREROUTING -p tcp -d GATEWAY_IP --dport 8082 -j DNAT --to-destination 172.16.6.1:8082
iptables -t nat -A PREROUTING -p tcp -d GATEWAY_IP --dport 443 -j DNAT --to-destination 172.16.6.0:443
iptables -t nat -A PREROUTING -p tcp -d GATEWAY_IP --dport 80 -j DNAT --to-destination 172.16.6.0:80
iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE # replace with whatever has the 172.16.6.0 subnet
iptables -P FORWARD ACCEPT
sysctl -w net.ipv4.ip_forward=1
```

Or configure something similar in your router.

For cloud hosting, this is very similar, but you can use the 172.0.0.1/24 subnet instead, e.g. 172.0.0.5-172.0.0.10

## Using a production certificate

Once your network is setup, and you are able to access Arcus (and get a certificate warning from the untrusted LetsEncrypt Staging CA), then it's time to setup a production certificate. Currently, this is done by making changes to config/service/ui-service-ingress.yml, although you shouldn't edit this file directly:

Run `./arcuscmd.sh useprodcert`

This will apply the configuration - wait a few minutes. You should no longer see a certificate warning when navigating to the site.

You can view cert-manager logs if you don't get a certificate:

`./arcuscmd.sh certlogs -f`

## DNS-01 certificates via Route 53

By default, cert-manager uses HTTP-01 challenges to verify domain ownership — it serves a token on port 80. This works for most setups, but DNS-01 challenges are required when:

- You need **wildcard certificates** (e.g. `*.arcus.example.com`)
- Your cluster is **not publicly accessible on port 80** (e.g. behind a firewall or NAT without port forwarding)

DNS-01 proves domain ownership by creating a TXT record in Route 53 instead of serving an HTTP response.

### AWS prerequisites

1. A **Route 53 hosted zone** for your domain
2. An **IAM user** (or role) with the following permissions on your hosted zone:
   - `route53:GetChange`
   - `route53:ChangeResourceRecordSets`
   - `route53:ListResourceRecordSets`

### Setup

Run `./arcuscmd.sh configure` and select `dns` when prompted for the certificate solver. You will be asked for:

- **Route 53 hosted zone ID** — stored in `.config/route53-hosted-zone-id`
- **AWS region** (e.g. `us-east-1`) — stored in `.config/route53-region`
- **AWS access key ID** — stored in `secret/route53-access-key-id`
- **AWS secret access key** — stored in `secret/route53-secret-access-key`

Then run `./arcuscmd.sh apply` to deploy the updated cert-manager configuration. The staging and production ClusterIssuers will use Route 53 for domain validation instead of HTTP-01.

You can verify your configuration at any time with `./arcuscmd.sh verifyconfig`.

## Multi-cluster traffic management

If you run multiple Arcus clusters behind Route 53 weighted records, you can use the `drain` and `resume` commands to shift traffic away from a cluster for maintenance.

### Prerequisites

- DNS-01 solver configured (see above)
- The `aws` CLI installed on the node
- A **Route 53 weighted record** pointing to this cluster
- The **set identifier** for this cluster's record, configured via `./arcuscmd.sh configure` or by writing it to `.config/route53-set-identifier`

### Usage

```bash
./arcuscmd.sh drain    # Set this cluster's Route 53 weight to 0 (stop receiving traffic)
./arcuscmd.sh resume   # Restore the previous weight (resume traffic)
```

`drain` saves the current weight to `.cache/route53-saved-weight` before setting it to 0. `resume` reads the saved weight and restores it, then removes the saved file.

### Typical maintenance workflow

1. `./arcuscmd.sh drain` — stop traffic to this cluster
2. Wait for in-flight requests to complete
3. Perform maintenance (upgrades, restarts, etc.)
4. `./arcuscmd.sh resume` — restore traffic

## Setting up the Hub Trust Store

Unfortunately, the hub-bridge doesn't work out of the box because it expects a Java Key Store, something we can't provide with cert-manager. Arcusplatform now supports PKCS#8 keys as well (via netty's internal support for PKCS#8), but the private key that cert-manager generates is in PKCS#1 format. As a result, you'll have to manually convert the private key to PKCS#8.

This can be accomplished by running `./arcuscmd.sh updatehubkeystore` once you have production certificates (see above).

## Backups

The only critical persistent system is Cassandra. For development, Cassandra can be run inside k3s using the manifests in the `local-production` overlay. For production, Cassandra should run on a dedicated 3-datacenter cluster external to Kubernetes — a single k3s node provides no real redundancy. Kafka and Zookeeper follow the same model.

Utility scripts have been provided to assist with backing up and restoring Cassandra. Typically you'd want to use snapshots to backup Cassandra, however in low-activity use cases like Arcus, you can also just make a tarball of the working directory and restore it.

## Troubleshooting

### View pod log

`./arcuscmd.sh logs kafka`

`./arcuscmd.sh logs cassandra`

## Adjusting configuration

The first time you setup Arcus, new secrets will be stored in the secrets directory. Once you have completed `./arcuscmd.sh setup`, feel free to adjust any of these secrets to your needs, and further uses of the setup tools in `./arcuscmd.sh` will not cause you to lose your secrets.

### Node configuration

Each node stores its local configuration in `.config/` (git-ignored). The easiest way to set these is:

`./arcuscmd.sh configure`

You can also write the files directly:

| File | Required | Description |
|---|---|---|
| `domain.name` | Yes | Main Arcus domain (e.g. `arcus.example.com`) |
| `admin.email` | Yes | Let's Encrypt admin email |
| `cert-issuer` | Yes | `staging` or `production` |
| `overlay-name` | Yes | Kustomize overlay to use (e.g. `local-production-cluster`) |
| `subnet` | MetalLB only | MetalLB IP range (e.g. `192.168.1.200-192.168.1.207`) |
| `metallb` | Optional | `yes` or `no` — enable MetalLB for load balancer IPs |
| `proxy-real-ip` | Optional | Upstream proxy IP/subnet for PROXY protocol (e.g. `192.168.1.1/32`) |
| `cassandra-host` | Optional | External Cassandra contact points (omit to use in-cluster) |
| `zookeeper-host` | Optional | External Zookeeper host (omit to use in-cluster) |
| `kafka-host` | Optional | External Kafka host (omit to use in-cluster) |
| `admin-domain` | Optional | Grafana admin domain (e.g. `admin.arcus-dc1.example.com`) |
| `cert-solver` | Optional | `http` (default) or `dns` — use DNS-01 challenges via Route 53 |
| `route53-hosted-zone-id` | If DNS solver | Route 53 hosted zone ID |
| `route53-region` | If DNS solver | AWS region for Route 53 (e.g. `us-east-1`) |
| `route53-set-identifier` | Optional | Route 53 set identifier for weighted record (used by `drain`/`resume`) |

You can also adjust the configuration in overlays/local-production-local/, however your changes will be lost if you run `./arcuscmd.sh apply`.

## Starting over

To completely remove k3s and all cluster data:

```
/usr/local/bin/k3s-uninstall.sh
```

This script is installed by k3s and removes the k3s installation, all pods, volumes, and configuration. Your local `.config/` and `secret/` directories are not affected.
