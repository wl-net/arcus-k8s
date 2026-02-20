# shellcheck shell=bash
# shared functions

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
  $KUBECTL create secret generic truststore --from-file irisbylowes/truststore.jks --dry-run=client -o yaml | $KUBECTL apply -f -
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
  for app in $APPS; do
    echo "Restarting ${app}..."
    $KUBECTL rollout restart deployment/"$app"
    $KUBECTL rollout status deployment/"$app" --timeout=120s
    echo "${app} ready."
  done
}


function killallpods() {
  echo "cassandra zookeeper kafka" | tr ' ' '\n' | xargs -P 2 -I{} "$KUBECTL" delete pod -l app={} --ignore-not-found 2>/dev/null
  echo "hub-bridge client-bridge" | tr ' ' '\n' | xargs -P 2 -I{} "$KUBECTL" delete pod -l app={} --ignore-not-found 2>/dev/null
  echo "driver-services rule-service scheduler-service" | tr ' ' '\n' | xargs -P 2 -I{} "$KUBECTL" delete pod -l app={} --ignore-not-found 2>/dev/null
  echo "alarm-service subsystem-service history-service ivr-callback-server notification-services platform-services ui-server" | tr ' ' '\n' | xargs -P 3 -I{} "$KUBECTL" delete pod -l app={} --ignore-not-found 2>/dev/null
}


function setup_k3s() {
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--disable=servicelb --disable=traefik --write-kubeconfig-mode 644' sh -
}

function setup_helm() {
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

function setup_istio() {
  $KUBECTL create namespace istio-system --dry-run=client -o yaml | $KUBECTL apply -f -

  $KUBECTL get crd gateways.gateway.networking.k8s.io &>/dev/null || \
    $KUBECTL kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.3.0" | $KUBECTL apply -f -

  helm repo add istio https://istio-release.storage.googleapis.com/charts
  helm repo update

  KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm upgrade --install istio-base istio/base \
    --namespace istio-system \
    --version "$ISTIO_VERSION" \
    --set defaultRevision=default \
    --create-namespace

  KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm upgrade --install istiod istio/istiod \
    --namespace istio-system \
    --version "$ISTIO_VERSION" \
    --set pilot.resources.requests.cpu=100m \
    --set pilot.resources.requests.memory=512M
}

function install() {
  $KUBECTL label namespace default istio-injection=enabled --overwrite

  local count
  count=$($KUBECTL get Issuers,ClusterIssuers,Certificates,CertificateRequests,Orders,Challenges --all-namespaces | grep cert-manager.io -c)
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
  $KUBECTL label namespace cert-manager certmanager.k8s.io/disable-validation=true --overwrite=true
  set -e

  if [[ -z "${DEPLOYMENT_TYPE:-}" ]]; then
    prompt DEPLOYMENT_TYPE "Is this a local or cloud deployment? [local/cloud]:"
    if [[ $DEPLOYMENT_TYPE != 'local' && $DEPLOYMENT_TYPE != 'cloud' ]]; then
      echo "Invalid option $DEPLOYMENT_TYPE, must pick 'local' or 'cloud'"
      exit 1
    fi
  fi

  if [[ $DEPLOYMENT_TYPE == 'local' ]]; then
    $KUBECTL apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
  fi
  $KUBECTL apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${NGINX_VERSION}/deploy/static/provider/baremetal/deploy.yaml"
  $KUBECTL apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

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
  echo "Connectivity Check:"
  for url in "${domains[@]}"; do
    local host="${url#https://}"
    local status enddate cert_info
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url")
    enddate=$(echo | openssl s_client -connect "${host}:443" -servername "$host" 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
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

  fi
}

function apply() {
  # Apply the configuration
  load

  if [[ -z "${ARCUS_DOMAIN_NAME:-}" || "${ARCUS_DOMAIN_NAME:-}" == "example.com" ]]; then
    echo "Error: Arcus is not configured. Please run './arcuscmd.sh configure' first."
    exit 1
  fi

  if [[ -z "${ARCUS_ADMIN_EMAIL:-}" || "${ARCUS_ADMIN_EMAIL:-}" == "me@example.com" ]]; then
    echo "Error: Arcus is not configured. Please run './arcuscmd.sh configure' first."
    exit 1
  fi

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

  if [[ $DEPLOYMENT_TYPE == 'local' ]]; then
    cp localk8s/metallb.yml "overlays/${ARCUS_OVERLAY_NAME}-local/metallb.yml"
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

  $KUBECTL apply -f config/certprovider/

  $KUBECTL apply -k "overlays/${ARCUS_OVERLAY_NAME}-local"
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

  if [[ $DEPLOYMENT_TYPE == 'local' && "$ARCUS_SUBNET" == "unconfigured" ]]; then
    echo "Arcus requires a pre-defined subnet for services to be served behind. This subnet must be unallocated (e.g. no IP addresses are used, *and* reserved for static clients)."
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

  echo "Arcus requires a verified address. In order to verify your address, you will need to create an account on https://smartystreets.com/"
  echo "Please go and create an account now, as you will be required to provide some details"
  echo "Make sure to create secret keys, since these credentials will only be used on the Arcus server, and never exposed to users"

  local authid authtoken apikey

  if [[ ! -e secret/smartystreets.authid ]]; then
    prompt authid "Please enter your smartystreets authid:"
    echo -n "$authid" > secret/smartystreets.authid
  fi

  if [[ ! -e secret/smartystreets.authtoken ]]; then
    prompt authtoken "Please enter your smartystreets authtoken:"
    echo -n "$authtoken" > secret/smartystreets.authtoken
  fi

  echo "Arcus requires a sendgrid API key for email notifications"

  if [[ ! -e secret/email.provider.apikey ]]; then
    prompt apikey "Please enter your sendgrid API key:"
    echo -n "$apikey" > secret/email.provider.apikey
  fi

  echo "Arcus requires Twilio to make phone calls"

  if [[ ! -e secret/twilio.account.auth ]]; then
    prompt apikey "Please enter your twilio auth:"
    echo -n "$apikey" > secret/twilio.account.auth
  fi

  if [[ ! -e secret/twilio.account.sid ]]; then
    prompt apikey "Please enter your twilio sid:"
    echo -n "$apikey" > secret/twilio.account.sid
  fi

  if [[ ! -e secret/twilio.account.from ]]; then
    prompt apikey "Please enter your twilio phone number:"
    echo -n "$apikey" > secret/twilio.account.from
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

  echo "Updated $branch: ${before:0:7} -> ${after:0:7}"
  git -C "$ROOT" --no-pager log --oneline "${before}..${after}"

  local config_changes
  config_changes=$(git -C "$ROOT" --no-pager diff --name-only "${before}..${after}" -- \
    'config/' 'overlays/' 'localk8s/' '*.yml' '*.yaml')

  if [[ -n "$config_changes" ]]; then
    echo ""
    echo "Changed manifests/overlays:"
    echo "${config_changes//$'\n'/$'\n'  }" | sed '1s/^/  /'
    echo ""
    local show_diff
    prompt show_diff "Show full diff of manifest changes? [yes/no]:"
    if [[ "$show_diff" == "yes" ]]; then
      git -C "$ROOT" --no-pager diff "${before}..${after}" -- \
        'config/' 'overlays/' 'localk8s/' '*.yml' '*.yaml'
    fi
  fi

  echo ""
  echo "Run './arcuscmd.sh apply' to deploy the new configuration."
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

  # subnet is required for local (k3s) deployments
  if [[ $DEPLOYMENT_TYPE == 'local' ]]; then
    if [[ ! -f "$ARCUS_CONFIGDIR/subnet" ]]; then
      echo "  MISSING: .config/subnet (required for local deployments)"
      ((errors++))
    elif [[ ! -s "$ARCUS_CONFIGDIR/subnet" ]]; then
      echo "  EMPTY:   .config/subnet (required for local deployments)"
      ((errors++))
    else
      echo "  OK:      .config/subnet = $(cat "$ARCUS_CONFIGDIR/subnet")"
    fi
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
  DATE=$(date '+%Y-%m-%d_%H-%M-%S')
  $KUBECTL exec cassandra-0 -- /bin/tar zcvf "/data/cassandra-${DATE}.tar.gz" cassandra
  $KUBECTL cp cassandra-0:/data/"cassandra-${DATE}.tar.gz" "cassandra-${DATE}.tar.gz"
  $KUBECTL exec cassandra-0 -- /bin/rm "/data/cassandra-${DATE}.tar.gz"
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
