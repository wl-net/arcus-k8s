# shellcheck shell=bash
# shared functions

function check_prerequisites() {
  local missing=()
  for cmd in curl git openssl sudo; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: required commands not found: ${missing[*]}"
    echo "Install them before running setup."
    return 1
  fi
}

function updatehubkeystore() {
  echo "Creating hub-keystore..."

  if ! $KUBECTL get secret nginx-production-tls &>/dev/null; then
    echo "Error: nginx-production-tls secret not found. Has a production certificate been issued?"
    exit 1
  fi

  mkdir -p converted
  $KUBECTL get secret nginx-production-tls -o jsonpath='{.data.tls\.key}' | base64 -d > converted/orig.key
  $KUBECTL get secret nginx-production-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > converted/tls.crt

  if ! openssl x509 -in converted/tls.crt -checkend 0 -noout &>/dev/null; then
    echo "Error: certificate has expired. Renew it before updating the hub keystore."
    rm -rf converted
    exit 1
  fi

  openssl pkcs8 -in converted/orig.key -topk8 -nocrypt -out converted/tls.key
  rm converted/orig.key

  $KUBECTL delete secret hub-keystore --ignore-not-found
  $KUBECTL create secret generic truststore --from-file util/truststore.jks --dry-run=client -o yaml | $KUBECTL apply -f -
  $KUBECTL create secret tls hub-keystore --cert converted/tls.crt --key converted/tls.key

  rm -rf converted
  echo "Hub keystore created with production certificate and trust store. Restart hub-bridge to pick up changes."
}

function useprodcert() {
  load
  echo 'production' > "$ARCUS_CONFIGDIR/cert-issuer"
  local ingress="overlays/${ARCUS_OVERLAY_NAME}-local/ui-service-ingress.yml"
  if [[ ! -f "$ingress" ]]; then
    echo "Error: $ingress not found. Run './arcuscmd.sh apply' first."
    exit 1
  fi
  sed -i 's/letsencrypt-staging/letsencrypt-production/g' "$ingress"
  sed -i 's/nginx-staging-tls/nginx-production-tls/g' "$ingress"
  $KUBECTL apply -f "$ingress"
}

function runmodelmanager() {
  set +e
  $KUBECTL delete pod -l app=modelmanager-platform
  $KUBECTL delete job modelmanager-platform

  $KUBECTL delete pod -l app=modelmanager-history
  $KUBECTL delete job modelmanager-history

  $KUBECTL delete pod -l app=modelmanager-video
  $KUBECTL delete job modelmanager-video

  set -e
  $KUBECTL apply -f config/jobs/
}

function provision() {
  echo "Setting up cassandra and kafka"
  retry 10 "$KUBECTL" exec cassandra-0 --stdin --tty -- '/bin/sh' '-c' 'CASSANDRA_KEYSPACE=production CASSANDRA_REPLICATION=1 CASSANDRA_HOSTNAME=localhost /usr/bin/cassandra-provision'
  retry 10 "$KUBECTL" exec kafka-0 --stdin --tty -- '/bin/sh' '-c' 'KAFKA_REPLICATION=1 KAFKAOPS_REPLICATION=1 kafka-cmd setup'
}

APPS='alarm-service client-bridge driver-services subsystem-service history-service hub-bridge ivr-callback-server notification-services platform-services rule-service scheduler-service ui-server'

# Deploy the platform in a way that causes minimal downtime
function deploy_platform() {
  local verify_output
  verify_output=$(verify_config 2>&1) || {
    echo "$verify_output"
    echo ""
    echo "Fix configuration issues before deploying, or run './arcuscmd.sh configure'."
    return 1
  }

  local pull=0
  if [[ "${1:-}" == "--pull" ]]; then
    pull=1
    shift
  fi

  local targets
  if [[ $# -gt 0 ]]; then
    targets="$*"
    for app in $targets; do
      if ! echo "$APPS" | tr ' ' '\n' | grep -qx "$app"; then
        echo "Error: unknown service '$app'"
        echo "Available: $APPS"
        return 1
      fi
    done
  else
    targets="$APPS"
  fi

  if [[ $pull -eq 1 ]]; then
    for app in $targets; do
      local image
      image=$($KUBECTL get deployment/"$app" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null) || true
      if [[ -z "$image" ]]; then
        echo "Warning: could not determine image for ${app}, skipping pull"
        continue
      fi
      echo "Pulling ${image}..."
      if sudo crictl pull "$image" 2>/dev/null; then
        echo "Pulled ${image}."
      else
        echo "Failed to pull ${image}, continuing with cached image."
      fi
    done
  fi

  for app in $targets; do
    echo "Restarting ${app}..."
    $KUBECTL rollout restart deployment/"$app"
    $KUBECTL rollout status deployment/"$app" --timeout=120s
    echo "${app} ready."
  done
}


function killallpods() {
  load
  if [[ "${ARCUS_OVERLAY_NAME:-}" == *cluster* ]]; then
    echo "WARNING: This will delete ALL pods including stateful services (Cassandra, Kafka, Zookeeper)."
    echo "Consider using './arcuscmd.sh deploy' for a safe rolling restart instead."
    echo ""
    local confirm
    prompt confirm "Are you sure you want to continue? [yes/no]:"
    if [[ "$confirm" != "yes" ]]; then
      echo "Aborted."
      return 0
    fi
  fi
  echo "cassandra zookeeper kafka" | tr ' ' '\n' | xargs -P 2 -I{} "$KUBECTL" delete pod -l app={} --ignore-not-found 2>/dev/null
  echo "hub-bridge client-bridge" | tr ' ' '\n' | xargs -P 2 -I{} "$KUBECTL" delete pod -l app={} --ignore-not-found 2>/dev/null
  echo "driver-services rule-service scheduler-service" | tr ' ' '\n' | xargs -P 2 -I{} "$KUBECTL" delete pod -l app={} --ignore-not-found 2>/dev/null
  echo "alarm-service subsystem-service history-service ivr-callback-server notification-services platform-services ui-server" | tr ' ' '\n' | xargs -P 3 -I{} "$KUBECTL" delete pod -l app={} --ignore-not-found 2>/dev/null
}


function setup_k3s() {
  curl -sfL https://get.k3s.io | sudo INSTALL_K3S_EXEC='--disable=servicelb --disable=traefik --write-kubeconfig-mode 644' sh -

  # Make kubectl work without KUBECONFIG being set
  mkdir -p "$HOME/.kube"
  cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
  chmod 600 "$HOME/.kube/config"
  echo "Kubeconfig written to ~/.kube/config"
}

function setup_helm() {
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
}

function setup_shell() {
  local shell_name rcfile
  shell_name=$(basename "$SHELL")

  case "$shell_name" in
    zsh)  rcfile="$HOME/.zshrc" ;;
    bash) rcfile="$HOME/.bashrc" ;;
    *)
      echo "Unsupported shell: $shell_name"
      echo "Add this to your shell config manually:"
      echo "  arcuscmd() { \"${ROOT}/arcuscmd.sh\" \"\$@\"; }"
      return 1
      ;;
  esac

  local func_line="arcuscmd() { \"${ROOT}/arcuscmd.sh\" \"\$@\"; }"

  if grep -qF 'arcuscmd()' "$rcfile" 2>/dev/null; then
    echo "arcuscmd is already in $rcfile"
    return 0
  fi

  {
    echo ""
    echo "# Arcus deployment CLI"
    echo "$func_line"
  } >> "$rcfile"
  echo "Added arcuscmd to $rcfile — run 'source $rcfile' or open a new terminal to use it."
}

function install_metallb() {
  if [[ "${ARCUS_METALLB:-no}" != "yes" ]]; then
    echo "Skipping MetalLB (not enabled — run './arcuscmd.sh configure' to enable)"
    return 0
  fi

  $KUBECTL apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
}

function install_nginx() {
  # Delete completed admission jobs — their spec.template is immutable and
  # kubectl apply will fail if they already exist from a previous install.
  $KUBECTL delete job -n ingress-nginx ingress-nginx-admission-create ingress-nginx-admission-patch 2>/dev/null || true
  $KUBECTL apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${NGINX_VERSION}/deploy/static/provider/baremetal/deploy.yaml"
}

function install_certmanager() {
  local count
  count=$($KUBECTL get Issuers,ClusterIssuers,Certificates,CertificateRequests,Orders,Challenges --all-namespaces 2>/dev/null | grep -c cert-manager.io || true)
  if [[ $count -gt 0 ]]; then
    echo "Removing cert-manager, please see https://docs.cert-manager.io/en/latest/tasks/uninstall/kubernetes.html for more details"
    set +e
    $KUBECTL delete -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
    $KUBECTL delete apiservice v1beta1.webhook.certmanager.k8s.io
    $KUBECTL delete apiservice v1beta1.admission.certmanager.k8s.io
    $KUBECTL delete apiservice v1alpha1.certmanager.k8s.io
    $KUBECTL delete namespace cert-manager
    set -e
  fi
  set +e
  $KUBECTL create namespace cert-manager 2>/dev/null
  $KUBECTL label namespace cert-manager certmanager.k8s.io/disable-validation=true --overwrite=true &>/dev/null
  set -e

  $KUBECTL apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
}

function install_istio() {
  $KUBECTL create namespace istio-system --dry-run=client -o yaml | $KUBECTL apply -f -

  $KUBECTL get crd gateways.gateway.networking.k8s.io &>/dev/null || \
    $KUBECTL kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.3.0" | $KUBECTL apply -f -

  helm repo add istio https://istio-release.storage.googleapis.com/charts
  helm repo update

  helm upgrade --install istio-base istio/base \
    --namespace istio-system \
    --version "$ISTIO_VERSION" \
    --set defaultRevision=default \
    --create-namespace

  helm upgrade --install istiod istio/istiod \
    --namespace istio-system \
    --version "$ISTIO_VERSION" \
    --set pilot.resources.requests.cpu=100m \
    --set pilot.resources.requests.memory=512M

  $KUBECTL label namespace default istio-injection=enabled --overwrite &>/dev/null || true
}

function install() {
  local targets=("$@")
  if [[ ${#targets[@]} -eq 0 ]]; then
    targets=(nginx cert-manager istio)
  fi
  for target in "${targets[@]}"; do
    case "$target" in
      metallb)      install_metallb ;;
      nginx)        install_nginx ;;
      cert-manager) install_certmanager ;;
      istio)        install_istio ;;
      *)
        echo "Unknown component: $target"
        echo "Available: metallb, nginx, cert-manager, istio"
        return 1
        ;;
    esac
  done
}

function info() {
  load
  IPADDRESS=$($KUBECTL describe service -n ingress-nginx | grep 'LoadBalancer Ingress:' | awk '{print $3}')
  HUB_IPADDRESS=$($KUBECTL describe service hub-bridge-service | grep 'LoadBalancer Ingress:' | awk '{print $3}')

  echo "DNS -> IP/Port Mappings: "
  echo "If these IP addresses are private, you are responsible for setting up port forwarding"
  echo ""
  echo "${ARCUS_DOMAIN_NAME}:80           -> $IPADDRESS:80"
  echo "${ARCUS_DOMAIN_NAME}:443          -> $IPADDRESS:443"
  echo "client.${ARCUS_DOMAIN_NAME}:443   -> $IPADDRESS:443"
  echo "static.${ARCUS_DOMAIN_NAME}:443   -> $IPADDRESS:443"
  echo "ipcd.${ARCUS_DOMAIN_NAME}:443     -> $IPADDRESS:443"
  echo "admin.${ARCUS_DOMAIN_NAME}:443    -> $IPADDRESS:443"
  echo "hub.${ARCUS_DOMAIN_NAME}:443      -> $IPADDRESS:443 OR $HUB_IPADDRESS:8082"
}

function connectivity_check() {
  load
  local public_ip
  local ip_cache=".cache/public-ip"
  mkdir -p .cache
  if [[ -f "$ip_cache" ]] && [[ $(( $(date +%s) - $(date -r "$ip_cache" +%s) )) -lt 3600 ]]; then
    public_ip=$(cat "$ip_cache")
  else
    public_ip=$(curl -s --max-time 5 ifconfig.me) || { echo "Failed to determine public IP"; exit 1; }
    echo "$public_ip" > "$ip_cache"
  fi
  echo "Public IP: $public_ip"
  echo ""

  local domains=(
    "https://${ARCUS_DOMAIN_NAME}"
    "https://client.${ARCUS_DOMAIN_NAME}"
    "https://static.${ARCUS_DOMAIN_NAME}"
  )
  [[ -n "${ARCUS_ADMIN_DOMAIN-}" ]] && domains+=("https://${ARCUS_ADMIN_DOMAIN}")

  local failed=0
  echo "DNS Resolution:"
  for url in "${domains[@]}"; do
    local host="${url#https://}"
    local resolved
    resolved=$(dig +short "$host" 2>/dev/null | tail -1)
    if [[ -z "$resolved" ]]; then
      resolved=$(getent hosts "$host" 2>/dev/null | awk '{print $1}')
    fi
    if [[ -z "$resolved" ]]; then
      printf "  %-50s [FAIL] not resolved\n" "$host"
      failed=1
    elif [[ "$resolved" != "$public_ip" ]]; then
      printf "  %-50s %s  [WARN] expected %s\n" "$host" "$resolved" "$public_ip"
    else
      printf "  %-50s %s  [OK]\n" "$host" "$resolved"
    fi
  done

  echo ""
  echo "Connectivity Check:"
  for url in "${domains[@]}"; do
    local host="${url#https://}"
    local status enddate cert_info
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url") || status="000"
    enddate=$(echo | openssl s_client -connect "${host}:443" -servername "$host" 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2) || true
    if [[ -n "$enddate" ]]; then
      cert_info=" (cert expires $enddate)"
    else
      cert_info=""
    fi
    if [[ "$status" =~ ^[23] ]]; then
      printf "  %-50s %s  [OK]%s\n" "$url" "$status" "$cert_info"
    else
      printf "  %-50s %s  [FAIL]%s\n" "$url" "$status" "$cert_info"
      failed=1
    fi
  done
  return $failed
}

function load() {
  ARCUS_OVERLAY_NAME="local-production"
  if [[ -d "$ARCUS_CONFIGDIR" ]]; then
    if [[ -f "$ARCUS_CONFIGDIR/admin.email" ]]; then
      ARCUS_ADMIN_EMAIL=$(cat "$ARCUS_CONFIGDIR/admin.email")
    fi
    if [[ -f "$ARCUS_CONFIGDIR/domain.name" ]]; then
      ARCUS_DOMAIN_NAME=$(cat "$ARCUS_CONFIGDIR/domain.name")
    fi
    if [[ -f "$ARCUS_CONFIGDIR/subnet" ]]; then
      ARCUS_SUBNET=$(cat "$ARCUS_CONFIGDIR/subnet")
    fi
    if [[ -f "$ARCUS_CONFIGDIR/cert-issuer" ]]; then
      ARCUS_CERT_TYPE=$(cat "$ARCUS_CONFIGDIR/cert-issuer")
    fi
    if [[ -f "$ARCUS_CONFIGDIR/overlay-name" ]]; then
      ARCUS_OVERLAY_NAME=$(cat "$ARCUS_CONFIGDIR/overlay-name")
    fi
    if [[ -f "$ARCUS_CONFIGDIR/cassandra-host" ]]; then
      ARCUS_CASSANDRA_HOST=$(cat "$ARCUS_CONFIGDIR/cassandra-host")
    fi
    if [[ -f "$ARCUS_CONFIGDIR/zookeeper-host" ]]; then
      ARCUS_ZOOKEEPER_HOST=$(cat "$ARCUS_CONFIGDIR/zookeeper-host")
    fi
    if [[ -f "$ARCUS_CONFIGDIR/kafka-host" ]]; then
      ARCUS_KAFKA_HOST=$(cat "$ARCUS_CONFIGDIR/kafka-host")
    fi
    if [[ -f "$ARCUS_CONFIGDIR/proxy-real-ip" ]]; then
      ARCUS_PROXY_REAL_IP=$(cat "$ARCUS_CONFIGDIR/proxy-real-ip")
    fi
    if [[ -f "$ARCUS_CONFIGDIR/admin-domain" ]]; then
      ARCUS_ADMIN_DOMAIN=$(cat "$ARCUS_CONFIGDIR/admin-domain")
    fi
    if [[ -f "$ARCUS_CONFIGDIR/metallb" ]]; then
      ARCUS_METALLB=$(cat "$ARCUS_CONFIGDIR/metallb")
    elif [[ -f "$ARCUS_CONFIGDIR/subnet" ]]; then
      # Upgrade path: existing installs that have a subnet configured were
      # using MetalLB before the opt-in flag existed.  Preserve that behavior.
      ARCUS_METALLB="yes"
    fi

  fi
}

function require_config() {
  load
  if [[ -z "${ARCUS_DOMAIN_NAME:-}" || "${ARCUS_DOMAIN_NAME:-}" == "example.com" ]]; then
    echo "Error: Arcus is not configured. Run './arcuscmd.sh configure' first."
    exit 1
  fi
}

function apply() {
  # Apply the configuration
  load

  if [ ! -d "overlays/${ARCUS_OVERLAY_NAME}" ] && [ "${ARCUS_OVERLAY_NAME}" != 'local-production-local' ]; then
    echo "Could not find overlay ${ARCUS_OVERLAY_NAME}"
    exit 1
  fi

  mkdir -p "overlays/${ARCUS_OVERLAY_NAME}-local"

  # Preserve user-customized tunable files before overwriting the overlay
  local arcus_tunable="overlays/${ARCUS_OVERLAY_NAME}-local/arcus-config-tunable.yml"
  local cluster_tunable="overlays/${ARCUS_OVERLAY_NAME}-local/cluster-config-tunable.yml"
  local saved_arcus_tunable="" saved_cluster_tunable=""
  [[ -f "$arcus_tunable" ]] && saved_arcus_tunable=$(cat "$arcus_tunable")
  [[ -f "$cluster_tunable" ]] && saved_cluster_tunable=$(cat "$cluster_tunable")

  cp -r "overlays/${ARCUS_OVERLAY_NAME}/"* "overlays/${ARCUS_OVERLAY_NAME}-local/"

  # Restore tunable files if user had customized them
  [[ -n "$saved_arcus_tunable" ]] && echo "$saved_arcus_tunable" > "$arcus_tunable"
  [[ -n "$saved_cluster_tunable" ]] && echo "$saved_cluster_tunable" > "$cluster_tunable"

  sed -i "s/me@example.com/$ARCUS_ADMIN_EMAIL/" "overlays/${ARCUS_OVERLAY_NAME}-local/cert-provider.yaml"

  cp config/configmaps/arcus-config.yml "overlays/${ARCUS_OVERLAY_NAME}-local/shared-config.yaml"
  sed -i "s/arcussmarthome.com/$ARCUS_DOMAIN_NAME/g" "overlays/${ARCUS_OVERLAY_NAME}-local/shared-config.yaml"

  cp config/configmaps/cluster-config.yml "overlays/${ARCUS_OVERLAY_NAME}-local/cluster-config.yml"

  if [[ -n "${ARCUS_CASSANDRA_HOST-}" ]]; then
    sed -i "s!cassandra.default.svc.cluster.local!${ARCUS_CASSANDRA_HOST}!g" "overlays/${ARCUS_OVERLAY_NAME}-local/cluster-config.yml"
  fi
  if [[ -n "${ARCUS_ZOOKEEPER_HOST-}" ]]; then
    sed -i "s!zookeeper-service.default.svc.cluster.local:2181!${ARCUS_ZOOKEEPER_HOST}!g" "overlays/${ARCUS_OVERLAY_NAME}-local/cluster-config.yml"
  fi
  if [[ -n "${ARCUS_KAFKA_HOST-}" ]]; then
    sed -i "s!kafka-service.default.svc.cluster.local:9092!${ARCUS_KAFKA_HOST}!g" "overlays/${ARCUS_OVERLAY_NAME}-local/cluster-config.yml"
  fi

  cp config/service/ui-service-ingress.yml "overlays/${ARCUS_OVERLAY_NAME}-local/"ui-service-ingress.yml
  sed -i "s/arcussmarthome.com/$ARCUS_DOMAIN_NAME/" "overlays/${ARCUS_OVERLAY_NAME}-local/ui-service-ingress.yml"

  if [[ "${ARCUS_METALLB:-}" == "yes" ]]; then
    cp config/templates/metallb.yml "overlays/${ARCUS_OVERLAY_NAME}-local/metallb.yml"
    sed -i "s!PLACEHOLDER_1!$ARCUS_SUBNET!" "overlays/${ARCUS_OVERLAY_NAME}-local/metallb.yml"
    $KUBECTL apply -f "overlays/${ARCUS_OVERLAY_NAME}-local/metallb.yml"
  fi

  if [[ -n "${ARCUS_PROXY_REAL_IP-}" ]]; then
    cp config/nginx-proxy.yml "overlays/${ARCUS_OVERLAY_NAME}-local/nginx-proxy.yml"
    sed -i "s!PLACEHOLDER_PROXY_IP!${ARCUS_PROXY_REAL_IP}!" "overlays/${ARCUS_OVERLAY_NAME}-local/nginx-proxy.yml"
    $KUBECTL apply -f "overlays/${ARCUS_OVERLAY_NAME}-local/nginx-proxy.yml"
  fi

  if [[ -n "${ARCUS_ADMIN_DOMAIN-}" ]]; then
    cp config/service/dc-admin-ingress.yml "overlays/${ARCUS_OVERLAY_NAME}-local/dc-admin-ingress.yml"
    sed -i "s!PLACEHOLDER_ADMIN_DOMAIN!${ARCUS_ADMIN_DOMAIN}!" "overlays/${ARCUS_OVERLAY_NAME}-local/dc-admin-ingress.yml"
    $KUBECTL apply -f "overlays/${ARCUS_OVERLAY_NAME}-local/dc-admin-ingress.yml"

    cp config/stateful/grafana.yaml "overlays/${ARCUS_OVERLAY_NAME}-local/grafana.yaml"
    sed -i "s!PLACEHOLDER_ADMIN_DOMAIN!${ARCUS_ADMIN_DOMAIN}!" "overlays/${ARCUS_OVERLAY_NAME}-local/grafana.yaml"
    $KUBECTL apply -f "overlays/${ARCUS_OVERLAY_NAME}-local/grafana.yaml"
  fi

  if [[ "${ARCUS_CERT_TYPE:-}" == 'production' ]]; then
    sed -i 's/letsencrypt-staging/letsencrypt-production/g' "overlays/${ARCUS_OVERLAY_NAME}-local/ui-service-ingress.yml"
    sed -i 's/nginx-staging-tls/nginx-production-tls/g' "overlays/${ARCUS_OVERLAY_NAME}-local/ui-service-ingress.yml"
  fi

  set +e
  $KUBECTL delete configmap extrafiles
  $KUBECTL create configmap extrafiles --from-file config/extrafiles
  set -e

  # Show what would change before applying.
  # kubectl diff exits 0 = no diff, 1 = has diff, >1 = error.
  local diff_exit=0
  $KUBECTL diff -k "overlays/${ARCUS_OVERLAY_NAME}-local" 2>/dev/null || diff_exit=$?
  if [[ $diff_exit -eq 0 ]]; then
    echo "No changes to apply."
  fi

  $KUBECTL apply -k "overlays/${ARCUS_OVERLAY_NAME}-local"

  mkdir -p "$ROOT/.cache"
  git -C "$ROOT" rev-parse HEAD > "$ROOT/.cache/last-applied-rev"
}

function configure() {
  load
  ARCUS_ADMIN_EMAIL=${ARCUS_ADMIN_EMAIL:-me@example.com}
  ARCUS_DOMAIN_NAME=${ARCUS_DOMAIN_NAME:-example.com}
  ARCUS_SUBNET=${ARCUS_SUBNET:-unconfigured}
  ARCUS_CERT_TYPE=${ARCUS_CERT_TYPE:-staging}
  ARCUS_PROXY_REAL_IP=${ARCUS_PROXY_REAL_IP:-}
  ARCUS_ADMIN_DOMAIN=${ARCUS_ADMIN_DOMAIN:-}

  if [ "$ARCUS_ADMIN_EMAIL" = "me@example.com" ]; then
    prompt ARCUS_ADMIN_EMAIL "Please enter your admin email address (or set ARCUS_ADMIN_EMAIL): "
  fi
  echo "$ARCUS_ADMIN_EMAIL" > "$ARCUS_CONFIGDIR/admin.email"

  if [ "$ARCUS_DOMAIN_NAME" = "example.com" ]; then
    prompt ARCUS_DOMAIN_NAME "Please enter your domain name (or set ARCUS_DOMAIN_NAME): "
  fi
  echo "$ARCUS_DOMAIN_NAME" > "$ARCUS_CONFIGDIR/domain.name"

  if [[ -z "$ARCUS_PROXY_REAL_IP" ]]; then
    local use_proxy
    prompt use_proxy "Is traffic arriving via a proxy that sends PROXY protocol (e.g. HAProxy, cloud LB)? [yes/no]:"
    if [[ "$use_proxy" == "yes" ]]; then
      prompt ARCUS_PROXY_REAL_IP "Enter upstream proxy IP/subnet (e.g. 192.168.1.1/32): "
      echo "$ARCUS_PROXY_REAL_IP" > "$ARCUS_CONFIGDIR/proxy-real-ip"
    fi
  fi

  if [[ -z "$ARCUS_ADMIN_DOMAIN" ]]; then
    local use_admin
    prompt use_admin "Do you have a separate admin (Grafana) domain? [yes/no]:"
    if [[ "$use_admin" == "yes" ]]; then
      prompt ARCUS_ADMIN_DOMAIN "Enter admin domain (e.g. admin.arcus-dc1.example.com): "
      echo "$ARCUS_ADMIN_DOMAIN" > "$ARCUS_CONFIGDIR/admin-domain"
    fi
  fi

  if [[ -z "${ARCUS_METALLB:-}" ]]; then
    # Auto-detect: if MetalLB is already running, default to yes and read its subnet
    if $KUBECTL get deployment -n metallb-system controller &>/dev/null; then
      ARCUS_METALLB="yes"
      echo "MetalLB detected in cluster — enabling automatically."
      if [[ "$ARCUS_SUBNET" == "unconfigured" ]]; then
        local detected_subnet
        detected_subnet=$($KUBECTL get ipaddresspool -n metallb-system arcus-pool -o jsonpath='{.spec.addresses[0]}' 2>/dev/null) || true
        if [[ -n "$detected_subnet" ]]; then
          ARCUS_SUBNET="$detected_subnet"
          echo "  Using existing subnet: $ARCUS_SUBNET"
          echo "$ARCUS_SUBNET" > "$ARCUS_CONFIGDIR/subnet"
        fi
      fi
    else
      local use_metallb
      prompt use_metallb "Do you need MetalLB for load balancer IPs? [yes/no]:"
      if [[ "$use_metallb" == "yes" ]]; then
        ARCUS_METALLB="yes"
      else
        ARCUS_METALLB="no"
      fi
    fi
    echo "$ARCUS_METALLB" > "$ARCUS_CONFIGDIR/metallb"
  fi

  if [[ "$ARCUS_METALLB" == "yes" && "$ARCUS_SUBNET" == "unconfigured" ]]; then
    echo "MetalLB requires a pre-defined subnet for services to be served behind. This subnet must be unallocated (e.g. no IP addresses are used, *and* reserved for static clients)."
    echo "Examples: 192.168.1.200/29, 192.168.1.200-192.168.1.207"
    prompt ARCUS_SUBNET "Please enter your subnet for Arcus services to be exposed on (or set ARCUS_SUBNET): "
    echo "$ARCUS_SUBNET" > "$ARCUS_CONFIGDIR/subnet"
  fi

  echo "$ARCUS_CERT_TYPE" > "$ARCUS_CONFIGDIR/cert-issuer"

  mkdir -p secret
  if [[ ! -e secret/billing.api.key ]]; then
    echo "Setting up default secret for billing.api.key"
    echo -n "12345" > secret/billing.api.key
  fi

  if [[ ! -e secret/billing.public.api.key ]]; then
    echo "Setting up default secret for billing.public.api.key"
    echo -n "12345" > secret/billing.public.api.key
  fi

  if [[ ! -e secret/iris.aes.iv ]]; then
    echo "Generating secret for iris.aes.iv"
    openssl rand -base64 8 | tr -d '\n' > secret/iris.aes.iv
  fi

  if [[ ! -e secret/iris.aes.secret ]]; then
    echo "Generating secret for iris.aes.secret"
    openssl rand -base64 32 | tr -d '\n' > secret/iris.aes.secret
  fi

  if [[ ! -e secret/questions.aes.secret ]]; then
    echo "Generating secret for questions.aes.secret"
    openssl rand -base64 32 | tr -d '\n' > secret/questions.aes.secret
  fi

  if [[ ! -e secret/smarty.auth.id ]]; then
    echo "Setting up default secret for smarty.auth.id"
    echo -n "12345" > secret/smarty.auth.id
  fi

  if [[ ! -e secret/smarty.auth.token ]]; then
    echo "Setting up default secret for smarty.auth.token"
    echo -n "12345" > secret/smarty.auth.token
  fi

  if [[ ! -e secret/tls.server.truststore.password ]]; then
    echo "Using *KNOWN DEFAULT* secret for tls.server.truststore.password"
    # note: the utility of truststore and keystore passwords is quesitonable.
    echo -n "8EFJhxm7aRs2hmmKwVuM9RPSwhNCtMpC" > secret/tls.server.truststore.password
  fi

  if [[ ! -e secret/apns.pkcs12.password ]]; then
    echo "Using *KNOWN DEFAULT* secret for apns.pkcs12.password"
    # note: the utility of truststore and keystore passwords is quesitonable.
    echo -n "8EFJhxm7aRs2hmmKwVuM9RPSwhNCtMpC" > secret/apns.pkcs12.password
  fi

  local authid authtoken apikey twilio_auth twilio_sid twilio_from skip_creds

  # Check if any external credentials still need configuration
  local needs_smarty=0 needs_sendgrid=0 needs_twilio=0
  [[ ! -e secret/smartystreets.authid || ! -e secret/smartystreets.authtoken ]] && needs_smarty=1
  [[ ! -e secret/email.provider.apikey ]] && needs_sendgrid=1
  [[ ! -e secret/twilio.account.auth || ! -e secret/twilio.account.sid || ! -e secret/twilio.account.from ]] && needs_twilio=1

  if [[ $((needs_smarty + needs_sendgrid + needs_twilio)) -gt 0 ]]; then
    echo ""
    echo "Arcus uses external services for address verification, email, and SMS."
    echo "You can configure these now, or skip and come back later with './arcuscmd.sh configure'."
    prompt skip_creds "Configure external service credentials now? [yes/no]:"
  else
    skip_creds="done"
  fi

  if [[ "$skip_creds" == "yes" ]]; then
    if [[ $needs_smarty -eq 1 ]]; then
      echo ""
      echo "SmartyStreets is required for address verification (https://smartystreets.com/)."
      echo "Create secret keys — these are only used on the server, never exposed to users."

      if [[ ! -e secret/smartystreets.authid ]]; then
        prompt authid "Please enter your smartystreets authid:"
        echo -n "$authid" > secret/smartystreets.authid
      fi

      if [[ ! -e secret/smartystreets.authtoken ]]; then
        prompt authtoken "Please enter your smartystreets authtoken:"
        echo -n "$authtoken" > secret/smartystreets.authtoken
      fi
    fi

    if [[ $needs_sendgrid -eq 1 ]]; then
      echo ""
      echo "Sendgrid is required for email notifications."

      if [[ ! -e secret/email.provider.apikey ]]; then
        prompt apikey "Please enter your sendgrid API key:"
        echo -n "$apikey" > secret/email.provider.apikey
      fi
    fi

    if [[ $needs_twilio -eq 1 ]]; then
      echo ""
      echo "Twilio is required for SMS/voice notifications."

      if [[ ! -e secret/twilio.account.auth ]]; then
        prompt twilio_auth "Please enter your twilio auth:"
        echo -n "$twilio_auth" > secret/twilio.account.auth
      fi

      if [[ ! -e secret/twilio.account.sid ]]; then
        prompt twilio_sid "Please enter your twilio sid:"
        echo -n "$twilio_sid" > secret/twilio.account.sid
      fi

      if [[ ! -e secret/twilio.account.from ]]; then
        prompt twilio_from "Please enter your twilio phone number:"
        echo -n "$twilio_from" > secret/twilio.account.from
      fi
    fi
  elif [[ "$skip_creds" != "done" ]]; then
    echo "Skipping external service credentials. Run './arcuscmd.sh configure' when you're ready to set them up."
  fi

  set +e
  $KUBECTL delete secret shared
  set -e
  $KUBECTL create secret generic shared --from-file secret/
}

function update() {
  local branch before after

  branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)
  before=$(git -C "$ROOT" rev-parse HEAD)

  local last_applied=""
  if [[ -f "$ROOT/.cache/last-applied-rev" ]]; then
    last_applied=$(cat "$ROOT/.cache/last-applied-rev")
  fi

  if [[ -n "$last_applied" && "$last_applied" != "$before" ]]; then
    echo "Warning: current revision (${before:0:7}) has not been applied (last applied: ${last_applied:0:7})"
    echo ""
  fi

  if ! git -C "$ROOT" diff --quiet; then
    echo "Warning: you have uncommitted changes"
    git -C "$ROOT" --no-pager diff --stat
    echo ""
  fi

  git -C "$ROOT" pull --ff-only --quiet || {
    echo "Fast-forward failed. You may have local commits that diverge from the remote."
    echo "Resolve manually with: git -C $ROOT rebase origin/$branch"
    return 1
  }

  after=$(git -C "$ROOT" rev-parse HEAD)

  if [[ "$before" == "$after" ]]; then
    echo "Already up to date on $branch (${after:0:7})."
    return 0
  fi

  mkdir -p "$ROOT/.cache"
  echo "$(date -Iseconds) $before $after" >> "$ROOT/.cache/update-history"

  echo "Updated $branch: ${before:0:7} -> ${after:0:7}"
  git -C "$ROOT" --no-pager log --oneline "${before}..${after}"

  local config_changes
  config_changes=$(git -C "$ROOT" --no-pager diff --name-only "${before}..${after}" -- \
    'config/' 'overlays/' '*.yml' '*.yaml')

  if [[ -n "$config_changes" ]]; then
    echo ""
    echo "Changed manifests/overlays:"
    echo "${config_changes//$'\n'/$'\n'  }" | sed '1s/^/  /'
    echo ""
    local show_diff
    prompt show_diff "Show full diff of manifest changes? [yes/no]:"
    if [[ "$show_diff" == "yes" ]]; then
      git -C "$ROOT" --no-pager diff "${before}..${after}" -- \
        'config/' 'overlays/' '*.yml' '*.yaml'
    fi
  fi

  echo ""
  echo "Run './arcuscmd.sh apply' to deploy the new configuration."
  echo "Run './arcuscmd.sh rollback' to revert to the previous version."
}

function update_history() {
  local history_file="$ROOT/.cache/update-history"
  if [[ ! -f "$history_file" ]]; then
    echo "No update history found."
    return 0
  fi

  local last_applied=""
  if [[ -f "$ROOT/.cache/last-applied-rev" ]]; then
    last_applied=$(cat "$ROOT/.cache/last-applied-rev")
  fi

  echo "Update history (most recent first):"
  echo ""
  local ts prev_rev new_rev status
  while read -r ts prev_rev new_rev; do
    if [[ -n "$last_applied" ]]; then
      if git -C "$ROOT" merge-base --is-ancestor "$new_rev" "$last_applied" 2>/dev/null; then
        status="[applied]"
      else
        status="[pending]"
      fi
    else
      status=""
    fi
    echo "  $ts  ${prev_rev:0:7} -> ${new_rev:0:7}  $status"
  done < <(tail -10 "$history_file" | tac)
}

function rollback() {
  local history_file="$ROOT/.cache/update-history"
  if [[ ! -f "$history_file" ]]; then
    echo "No update history found. Nothing to roll back to."
    return 1
  fi

  local count
  count=$(wc -l < "$history_file")

  if [[ "$count" -eq 1 ]]; then
    local ts prev_rev new_rev
    read -r ts prev_rev new_rev < "$history_file"
    echo "Rolling back to ${prev_rev:0:7} (before update at $ts)"
    git -C "$ROOT" checkout "$prev_rev"
    echo "Rolled back. Run './arcuscmd.sh apply' to deploy."
    return 0
  fi

  echo "Recent updates (most recent first):"
  echo ""
  local i=0
  local -a revs timestamps
  while read -r ts prev_rev new_rev; do
    revs+=("$prev_rev")
    timestamps+=("$ts")
    echo "  $((i + 1))) $ts  ${prev_rev:0:7} -> ${new_rev:0:7}"
    ((i++))
  done < <(tail -10 "$history_file" | tac)

  echo ""
  local choice
  prompt choice "Roll back to which version? [1-$i]:"
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "$i" ]]; then
    echo "Invalid selection."
    return 1
  fi

  local target="${revs[$((choice - 1))]}"
  echo "Rolling back to ${target:0:7} (before update at ${timestamps[$((choice - 1))]})"
  git -C "$ROOT" checkout "$target"
  echo "Rolled back. Run './arcuscmd.sh apply' to deploy."
}

function logs() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: arcuscmd logs <app> [--follow] [--tail=N]"
    exit 1
  fi
  local app=$1
  shift
  local pod
  pod=$($KUBECTL get pod -l app="$app" --field-selector=status.phase=Running -o name | head -1)
  if [[ -z "$pod" ]]; then
    echo "Error: no running pod found for app=$app"
    exit 1
  fi
  $KUBECTL logs --tail=1000 -c "$app" "$pod" "$@"
}

function certlogs() {
  local component=cert-manager
  if [[ $# -gt 0 && $1 != -* ]]; then
    component=$1
    shift
  fi
  $KUBECTL logs --tail=1000 -n cert-manager -l app.kubernetes.io/name="$component" "$@"
}

function delete() {
  $KUBECTL delete pod -l app="$1"
}

function shell_exec() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: arcuscmd shell <app> [command]"
    exit 1
  fi
  local app=$1
  shift
  local pod
  pod=$($KUBECTL get pod -l app="$app" -o name | head -1)
  if [[ -z "$pod" ]]; then
    echo "Error: no running pod found for app=$app"
    exit 1
  fi
  local cmd=(/bin/sh)
  if [[ $# -gt 0 ]]; then
    cmd=("$@")
  fi
  $KUBECTL exec --stdin --tty "$pod" -- "${cmd[@]}"
}

function verify_config() {
  load

  local errors=0
  local warnings=0

  echo "Verifying Arcus configuration..."
  echo

  # --- Required .config files ---
  echo "=== Node Configuration (.config/) ==="

  for file in domain.name admin.email cert-issuer; do
    if [[ ! -f "$ARCUS_CONFIGDIR/$file" ]]; then
      echo "  MISSING: .config/$file (required)"
      ((errors++))
    elif [[ ! -s "$ARCUS_CONFIGDIR/$file" ]]; then
      echo "  EMPTY:   .config/$file (required)"
      ((errors++))
    else
      echo "  OK:      .config/$file = $(cat "$ARCUS_CONFIGDIR/$file")"
    fi
  done

  # overlay-name defaults to local-production in load(), so missing is fine but we still report it
  if [[ -f "$ARCUS_CONFIGDIR/overlay-name" ]]; then
    echo "  OK:      .config/overlay-name = $(cat "$ARCUS_CONFIGDIR/overlay-name")"
  else
    echo "  DEFAULT: .config/overlay-name (using local-production)"
  fi

  # subnet is required when MetalLB is enabled
  if [[ "${ARCUS_METALLB:-}" == "yes" ]]; then
    if [[ ! -f "$ARCUS_CONFIGDIR/subnet" ]]; then
      echo "  MISSING: .config/subnet (required when MetalLB is enabled)"
      ((errors++))
    elif [[ ! -s "$ARCUS_CONFIGDIR/subnet" ]]; then
      echo "  EMPTY:   .config/subnet (required when MetalLB is enabled)"
      ((errors++))
    else
      echo "  OK:      .config/subnet = $(cat "$ARCUS_CONFIGDIR/subnet")"
    fi
  fi

  # metallb config
  if [[ -f "$ARCUS_CONFIGDIR/metallb" ]]; then
    echo "  OK:      .config/metallb = $(cat "$ARCUS_CONFIGDIR/metallb")"
  else
    echo "  DEFAULT: .config/metallb (MetalLB not configured — run configure to set)"
  fi

  # Optional config files
  for file in proxy-real-ip cassandra-host zookeeper-host kafka-host admin-domain; do
    if [[ -f "$ARCUS_CONFIGDIR/$file" ]]; then
      echo "  OK:      .config/$file = $(cat "$ARCUS_CONFIGDIR/$file")"
    fi
  done

  echo

  # --- Validate config values ---
  echo "=== Value Checks ==="

  if [[ "${ARCUS_DOMAIN_NAME:-}" == "example.com" ]]; then
    echo "  ERROR:   domain.name is still the placeholder (example.com)"
    ((errors++))
  elif [[ -n "${ARCUS_DOMAIN_NAME:-}" ]]; then
    echo "  OK:      domain.name looks valid"
  fi

  if [[ "${ARCUS_ADMIN_EMAIL:-}" == "me@example.com" ]]; then
    echo "  ERROR:   admin.email is still the placeholder (me@example.com)"
    ((errors++))
  elif [[ -n "${ARCUS_ADMIN_EMAIL:-}" ]]; then
    echo "  OK:      admin.email looks valid"
  fi

  if [[ -n "${ARCUS_CERT_TYPE:-}" ]]; then
    if [[ "$ARCUS_CERT_TYPE" != "staging" && "$ARCUS_CERT_TYPE" != "production" ]]; then
      echo "  ERROR:   cert-issuer has invalid value '$ARCUS_CERT_TYPE' (must be staging or production)"
      ((errors++))
    else
      echo "  OK:      cert-issuer = $ARCUS_CERT_TYPE"
    fi
  fi

  # Check that the overlay directory exists
  if [[ ! -d "overlays/${ARCUS_OVERLAY_NAME}" ]]; then
    echo "  ERROR:   overlay directory overlays/${ARCUS_OVERLAY_NAME} does not exist"
    ((errors++))
  else
    echo "  OK:      overlay directory overlays/${ARCUS_OVERLAY_NAME} exists"
  fi

  echo

  # --- Secrets ---
  echo "=== Secrets (secret/) ==="

  local required_secrets=(
    billing.api.key
    billing.public.api.key
    iris.aes.iv
    iris.aes.secret
    questions.aes.secret
    smarty.auth.id
    smarty.auth.token
    tls.server.truststore.password
    apns.pkcs12.password
    smartystreets.authid
    smartystreets.authtoken
    email.provider.apikey
    twilio.account.auth
    twilio.account.sid
    twilio.account.from
  )

  if [[ ! -d secret ]]; then
    echo "  MISSING: secret/ directory does not exist"
    ((errors += ${#required_secrets[@]}))
  else
    for s in "${required_secrets[@]}"; do
      if [[ ! -f "secret/$s" ]]; then
        echo "  MISSING: secret/$s"
        ((errors++))
      elif [[ ! -s "secret/$s" ]]; then
        echo "  EMPTY:   secret/$s"
        ((errors++))
      else
        echo "  OK:      secret/$s"
      fi
    done
  fi

  # Warn about placeholder secrets
  for s in smarty.auth.id smarty.auth.token billing.api.key billing.public.api.key; do
    if [[ -f "secret/$s" ]] && [[ "$(cat "secret/$s")" == "12345" ]]; then
      echo "  WARNING: secret/$s still has the default placeholder value"
      ((warnings++))
    fi
  done

  echo
  echo "=== Summary ==="
  if [[ $errors -eq 0 && $warnings -eq 0 ]]; then
    echo "  Configuration is complete. No issues found."
  else
    [[ $warnings -gt 0 ]] && echo "  $warnings warning(s)"
    [[ $errors -gt 0 ]] && echo "  $errors error(s) — run './arcuscmd.sh configure' to fix"
  fi

  return "$errors"
}

function backup_config() {
  DATE=$(date '+%Y-%m-%d_%H-%M-%S')
  BACKUP_FILE="arcus-config-backup-${DATE}.tar.gz"

  DIRS=()
  for dir in .config secret overlays/local-production-local overlays/local-production-cluster-local; do
    if [[ -d "${ROOT}/${dir}" ]]; then
      DIRS+=("${dir}")
    fi
  done

  if [[ ${#DIRS[@]} -eq 0 ]]; then
    echo "Nothing to back up — no local configuration directories found."
    exit 1
  fi

  echo "Backing up: ${DIRS[*]}"
  tar -czf "${BACKUP_FILE}" -C "${ROOT}" "${DIRS[@]}"
  echo "Configuration saved to ${BACKUP_FILE}"
}

function backup_cassandra() {
  local date_stamp
  date_stamp=$(date '+%Y-%m-%d_%H-%M-%S')

  echo "Clearing old snapshots..."
  $KUBECTL exec cassandra-0 -- /opt/cassandra/bin/nodetool clearsnapshot
  echo "Taking snapshot..."
  $KUBECTL exec cassandra-0 -- /opt/cassandra/bin/nodetool snapshot -t arcus-backup
  echo "Exporting schema..."
  $KUBECTL exec cassandra-0 -- /bin/bash -c '/usr/bin/cqlsh -e "DESCRIBE SCHEMA" > keyspaces.cqlsh'
  echo "Creating tarball..."
  # shellcheck disable=SC2016
  $KUBECTL exec cassandra-0 -- /bin/bash -c '/bin/tar czf "/data/cassandra-backup.tar.gz" $(find /data/cassandra -type d -name arcus-backup) keyspaces.cqlsh'
  $KUBECTL cp cassandra-0:/data/cassandra-backup.tar.gz "cassandra-${date_stamp}.tar.gz"
  $KUBECTL exec cassandra-0 -- /bin/rm /data/cassandra-backup.tar.gz
  echo "Backup saved to cassandra-${date_stamp}.tar.gz"
}

function restore_cassandra_snapshot() {
  if [[ $# -eq 0 || -z "$1" ]]; then
    echo "Usage: arcuscmd restoredb <backup-file.tar.gz>"
    return 1
  fi
  local file=$1
  if [[ ! -f "$file" ]]; then
    echo "Error: file not found: $file"
    return 1
  fi

  echo "Copying backup to pod..."
  $KUBECTL cp "$file" cassandra-0:/data/cassandra-restore.tar.gz
  echo "Extracting..."
  $KUBECTL exec cassandra-0 -- /bin/mkdir -p /data/restore
  $KUBECTL exec cassandra-0 -- /bin/tar xzf /data/cassandra-restore.tar.gz -C /data/restore
  $KUBECTL exec cassandra-0 -- /bin/rm /data/cassandra-restore.tar.gz
  echo "Applying schema..."
  $KUBECTL exec cassandra-0 -- /bin/bash -c 'cd /data/restore; /usr/bin/cqlsh < /data/restore/keyspaces.cqlsh'
  echo "Loading SSTables..."
  # shellcheck disable=SC2016
  $KUBECTL exec cassandra-0 -- /bin/bash -c 'cd /data/restore; for i in $(find . -type d -name arcus-backup); do cp $i/* $i/../.. && /opt/cassandra/bin/sstableloader -d localhost $(echo $i | sed "s/snapshots\/arcus-backup//"); done'
  $KUBECTL exec cassandra-0 -- /bin/rm -rf /data/restore
  echo "Restore complete. You may need to restart some pods to make the system consistent."
}

function restore_cassandra_full() {
  if [[ $# -eq 0 || -z "$1" ]]; then
    echo "Usage: arcuscmd restoredb-full <backup-file.tar.gz>"
    return 1
  fi
  local file=$1
  if [[ ! -f "$file" ]]; then
    echo "Error: file not found: $file"
    return 1
  fi

  echo "WARNING: This will replace the entire Cassandra data directory and kill the Cassandra process."
  echo "The pod will restart automatically, but there will be downtime."
  local confirm
  prompt confirm "Are you sure you want to continue? [yes/no]:"
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    return 0
  fi

  echo "Copying backup to pod..."
  $KUBECTL cp "$file" cassandra-0:/data/cassandra-restore.tar.gz
  echo "Moving old data directory..."
  $KUBECTL exec cassandra-0 -- /bin/mv /data/cassandra /data/cassandra-old
  echo "Extracting..."
  $KUBECTL exec cassandra-0 -- /bin/tar xzf /data/cassandra-restore.tar.gz
  $KUBECTL exec cassandra-0 -- /bin/rm /data/cassandra-restore.tar.gz
  $KUBECTL exec cassandra-0 -- /bin/sync
  echo "Killing Cassandra process (pod will restart)..."
  $KUBECTL exec cassandra-0 -- /usr/bin/killall java
  echo "Full restore complete. Cassandra will restart with the restored data."
}

function setup_metrics() {
  $KUBECTL apply -f config/stateful/grafana.yaml
}

function arcus_status() {
  load
  echo "Application Services:"
  set +e
  # shellcheck disable=SC2086
  $KUBECTL get deployments $APPS --ignore-not-found
  set -e

  local found_stateful=()
  for svc in cassandra kafka zookeeper; do
    if $KUBECTL get statefulset "$svc" &>/dev/null; then
      found_stateful+=("$svc")
    fi
  done

  if [[ ${#found_stateful[@]} -gt 0 ]]; then
    echo ""
    echo "Stateful Services:"
    $KUBECTL get statefulset "${found_stateful[@]}"
  fi

  local external_hosts=()
  [[ -n "${ARCUS_CASSANDRA_HOST-}" ]] && external_hosts+=("cassandra:${ARCUS_CASSANDRA_HOST%%:*}")
  [[ -n "${ARCUS_KAFKA_HOST-}" ]]     && external_hosts+=("kafka:${ARCUS_KAFKA_HOST%%:*}")
  [[ -n "${ARCUS_ZOOKEEPER_HOST-}" ]] && external_hosts+=("zookeeper:${ARCUS_ZOOKEEPER_HOST%%:*}")

  if [[ ${#external_hosts[@]} -gt 0 ]]; then
    echo ""
    echo "External Services:"
    for entry in "${external_hosts[@]}"; do
      local name="${entry%%:*}"
      local hosts_str="${entry#*:}"
      IFS=',' read -ra hosts <<< "$hosts_str"
      for host in "${hosts[@]}"; do
        host="${host// /}"  # trim spaces
        if ping -c 1 -W 2 "$host" &>/dev/null; then
          printf "  %-16s %s  [OK]\n" "$name" "$host"
        else
          printf "  %-16s %s  [UNREACHABLE]\n" "$name" "$host"
        fi
      done
    done
  fi

  local found_certs=0
  for secret in nginx-staging-tls nginx-production-tls dc-admin-production-tls; do
    if $KUBECTL get secret "$secret" &>/dev/null; then
      if [[ $found_certs -eq 0 ]]; then
        echo ""
        echo "Certificates:"
        found_certs=1
      fi
      local cert enddate
      cert=$($KUBECTL get secret "$secret" -o jsonpath='{.data.tls\.crt}' | base64 -d)
      enddate=$(echo "$cert" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      if echo "$cert" | openssl x509 -checkend 0 -noout &>/dev/null; then
        echo "  $secret: valid, expires $enddate"
      else
        echo "  $secret: EXPIRED ($enddate)"
      fi
    fi
  done

  echo ""
  infra_versions
}

function infra_versions() {
  echo "Infrastructure:"
  set +e
  _infra_version_check "metallb" \
    "$($KUBECTL get deployment -n metallb-system controller -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP 'v[\d.]+')" \
    "$METALLB_VERSION"
  _infra_version_check "ingress-nginx" \
    "$($KUBECTL get deployment -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP 'v[\d.]+')" \
    "$NGINX_VERSION"
  _infra_version_check "cert-manager" \
    "$($KUBECTL get deployment -n cert-manager cert-manager -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP 'v[\d.]+')" \
    "$CERT_MANAGER_VERSION"
  _infra_version_check "istio" \
    "$($KUBECTL get deployment -n istio-system istiod -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP '[\d.]+$')" \
    "$ISTIO_VERSION"
  set -e
}

function validate_manifests() {
  local errors=0

  echo "=== YAML Syntax ==="
  while IFS= read -r f; do
    local err
    if err=$(python3 -c "import yaml, sys; list(yaml.safe_load_all(open(sys.argv[1])))" "$f" 2>&1); then
      echo "  OK:   $f"
    else
      echo "  FAIL: $f"
      while IFS= read -r line; do echo "        $line"; done <<< "$err"
      ((errors++))
    fi
  done < <(find config/ overlays/ -name '*.yml' -o -name '*.yaml' | sort)

  echo ""
  echo "=== Kustomize Build ==="
  if $KUBECTL kustomize config > /dev/null 2>&1; then
    echo "  OK:   config/ builds cleanly"
  else
    echo "  FAIL: config/ kustomize build failed"
    $KUBECTL kustomize config 2>&1 | sed 's/^/  /'
    ((errors++))
  fi

  echo ""
  echo "=== Kubernetes Schema ==="
  if command -v kubeconform &>/dev/null; then
    local kc_output
    kc_output=$($KUBECTL kustomize config 2>/dev/null \
      | kubeconform -summary -strict \
          -ignore-missing-schemas \
          -kubernetes-version 1.32.0 2>&1)
    local kc_exit=$?
    # shellcheck disable=SC2001
    echo "$kc_output" | sed 's/^/  /'
    if [[ $kc_exit -ne 0 ]]; then
      ((errors++))
    fi
  else
    echo "  SKIP: kubeconform not installed (install from https://github.com/yannh/kubeconform)"
  fi

  echo ""
  if [[ $errors -eq 0 ]]; then
    echo "Validation passed."
  else
    echo "$errors check(s) failed."
    return 1
  fi
}

function _infra_version_check() {
  local name=$1 installed=$2 configured=$3
  if [[ -z "$installed" ]]; then
    printf "  %-16s not installed\n" "$name"
  elif [[ "$installed" == "$configured" ]]; then
    printf "  %-16s %s  [OK]\n" "$name" "$installed"
  else
    printf "  %-16s installed=%-10s configured=%-10s [UPGRADE AVAILABLE]\n" "$name" "$installed" "$configured"
  fi
}
