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
  echo 'production' > $ARCUS_CONFIGDIR/cert-issuer
  sed -i 's/letsencrypt-staging/letsencrypt-production/g' overlays/local-production-local/ui-service-ingress.yml
  sed -i 's/nginx-staging-tls/nginx-production-tls/g' overlays/local-production-local/ui-service-ingress.yml
  $KUBECTL apply -f overlays/local-production-local/ui-service-ingress.yml
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
  retry 10 $KUBECTL exec cassandra-0 --stdin --tty -- '/bin/sh' '-c' 'CASSANDRA_KEYSPACE=production CASSANDRA_REPLICATION=1 CASSANDRA_HOSTNAME=localhost /usr/bin/cassandra-provision'
  retry 10 $KUBECTL exec kafka-0 --stdin --tty -- '/bin/sh' '-c' 'KAFKA_REPLICATION=1 KAFKAOPS_REPLICATION=1 kafka-cmd setup'
}

APPS='alarm-service client-bridge driver-services subsystem-service history-service hub-bridge ipcd-bridge ivr-callback-server metrics-server notification-services platform-services rule-service scheduler-service ui-server'

# Deploy the platform in a way that causes minimal downtime
function deploy_platform() {
  for app in $APPS; do
    $KUBECTL scale deployments/$app --replicas=2
    echo "Waiting for ${app} to come online..."
    sleep 15
    if [[ $app == 'driver-services' ]]; then
      echo "driver-services..."
      sleep 50
    fi

    to_delete=$($KUBECTL get pods --sort-by=.metadata.creationTimestamp -o custom-columns=":metadata.name" | grep $app | head -1)
    $KUBECTL delete pod $to_delete
    $KUBECTL scale deployments/$app --replicas=1
  done
}

# Deploy "fast"
function deployfast() {
  # Always kill the khakis containers first to avoid failures later.
  $KUBECTL delete pod -l app=cassandra
  $KUBECTL delete pod -l app=zookeeper
  $KUBECTL delete pod -l app=kafka

  for app in $APPS; do
    $KUBECTL delete pod -l app=$app
    sleep 5
  done
}

function killallpods() {
  echo "cassandra zookeeper kafka" | tr ' ' '\n' | xargs -P 2 -I{} $KUBECTL delete pod -l app={} --ignore-not-found 2>/dev/null
  echo "hub-bridge client-bridge" | tr ' ' '\n' | xargs -P 2 -I{} $KUBECTL delete pod -l app={} --ignore-not-found 2>/dev/null
  echo "driver-services rule-service scheduler-service" | tr ' ' '\n' | xargs -P 2 -I{} $KUBECTL delete pod -l app={} --ignore-not-found 2>/dev/null
  echo "alarm-service subsystem-service history-service ipcd-bridge ivr-callback-server metrics-server notification-services platform-services ui-server" | tr ' ' '\n' | xargs -P 3 -I{} $KUBECTL delete pod -l app={} --ignore-not-found 2>/dev/null
}


function setup_k3s() {
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--disable=servicelb --disable=traefik --write-kubeconfig-mode 644' sh -
}

function setup_helm() {
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

function setup_istio() {
  set +e
  $KUBECTL create namespace istio-system
  set -e
  mkdir -p .temp
  cd .temp
  curl -L https://git.io/getLatestIstio | sh -
  cd "istio-${ISTIO_VERSION}"
  $KUBECTL get crd gateways.gateway.networking.k8s.io &> /dev/null || { kubectl kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.3.0-rc.1" | kubectl apply -f -; }
  helm repo add istio https://istio-release.storage.googleapis.com/charts
  helm repo update
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm install istio-base istio/base -n istio-system --set defaultRevision=default --create-namespace
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm install istiod istio/istiod --namespace istio-system --set mixer.telemetry.resources.requests.cpu=100m --set mixer.telemetry.resources.requests.memory=256Mi --set pilot.resources.requests.cpu=100m --set pilot.resources.requests.memory=512M
  cd -
  cd .. # leave .temp
}

function install() {
  $KUBECTL label namespace default istio-injection=enabled --overwrite

  local count=$($KUBECTL get Issuers,ClusterIssuers,Certificates,CertificateRequests,Orders,Challenges --all-namespaces | grep cert-manager.io -c)
  if [[ $count -gt 0 ]]; then
    echo "Removing cert-manager, please see https://docs.cert-manager.io/en/latest/tasks/uninstall/kubernetes.html for more details"
    set +e
    $KUBECTL delete -f https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml
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
    $KUBECTL apply -f https://raw.githubusercontent.com/metallb/metallb/$METALLB_VERSION/config/manifests/metallb-native.yaml
  fi
  $KUBECTL apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-$NGINX_VERSION/deploy/static/provider/baremetal/deploy.yaml
  $KUBECTL apply -f https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml

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

function load() {
  ARCUS_OVERLAY_NAME="local-production"
  if [ -d $ARCUS_CONFIGDIR ]; then
    if [ -f "$ARCUS_CONFIGDIR/admin.email" ]; then
      ARCUS_ADMIN_EMAIL=$(cat $ARCUS_CONFIGDIR/admin.email)
    fi
    if [ -f "$ARCUS_CONFIGDIR/domain.name" ]; then
      ARCUS_DOMAIN_NAME=$(cat $ARCUS_CONFIGDIR/domain.name)
    fi
    if [ -f "$ARCUS_CONFIGDIR/subnet" ]; then
      ARCUS_SUBNET=$(cat $ARCUS_CONFIGDIR/subnet)
    fi
    if [ -f "$ARCUS_CONFIGDIR/cert-issuer" ]; then
      ARCUS_CERT_TYPE=$(cat $ARCUS_CONFIGDIR/cert-issuer)
    fi
    if [ -f "$ARCUS_CONFIGDIR/overlay-name" ]; then
      ARCUS_OVERLAY_NAME=$(cat $ARCUS_CONFIGDIR/overlay-name)
    fi
    if [ -f "$ARCUS_CONFIGDIR/cassandra-host" ]; then
      ARCUS_CASSANDRA_HOST=$(cat $ARCUS_CONFIGDIR/cassandra-host)
    fi
    if [ -f "$ARCUS_CONFIGDIR/zookeeper-host" ]; then
      ARCUS_ZOOKEEPER_HOST=$(cat $ARCUS_CONFIGDIR/zookeeper-host)
    fi
    if [ -f "$ARCUS_CONFIGDIR/kafka-host" ]; then
      ARCUS_KAFKA_HOST=$(cat $ARCUS_CONFIGDIR/kafka-host)
    fi

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
  cp -r "overlays/${ARCUS_OVERLAY_NAME}/"* "overlays/${ARCUS_OVERLAY_NAME}-local/"

  sed -i "s/me@example.com/$ARCUS_ADMIN_EMAIL/" "overlays/${ARCUS_OVERLAY_NAME}-local/cert-provider.yaml"

  cp config/configmaps/arcus-config.yml "overlays/${ARCUS_OVERLAY_NAME}-local/shared-config.yaml"
  sed -i "s/arcussmarthome.com/$ARCUS_DOMAIN_NAME/g" "overlays/${ARCUS_OVERLAY_NAME}-local/shared-config.yaml"

  cp config/configmaps/cluster-config.yml "overlays/${ARCUS_OVERLAY_NAME}-local/cluster-config.yml"

  if [[ ! -z "${ARCUS_CASSANDRA_HOST-}" ]]; then
    sed -i "s!cassandra.default.svc.cluster.local!${ARCUS_CASSANDRA_HOST}!g" "overlays/${ARCUS_OVERLAY_NAME}-local/cluster-config.yml"
  fi
  if [[ ! -z "${ARCUS_ZOOKEEPER_HOST-}" ]]; then
    sed -i "s!zookeeper-service.default.svc.cluster.local:2181!${ARCUS_ZOOKEEPER_HOST}!g" "overlays/${ARCUS_OVERLAY_NAME}-local/cluster-config.yml"
  fi
  if [[ ! -z "${ARCUS_KAFKA_HOST-}" ]]; then
    sed -i "s!kafka-service.default.svc.cluster.local:9092!${ARCUS_KAFKA_HOST}!g" "overlays/${ARCUS_OVERLAY_NAME}-local/cluster-config.yml"
  fi

  cp config/service/ui-service-ingress.yml "overlays/${ARCUS_OVERLAY_NAME}-local/"ui-service-ingress.yml
  sed -i "s/arcussmarthome.com/$ARCUS_DOMAIN_NAME/" "overlays/${ARCUS_OVERLAY_NAME}-local/ui-service-ingress.yml"

  cp localk8s/metallb.yml "overlays/${ARCUS_OVERLAY_NAME}-local/metallb.yml"
  sed -i "s!PLACEHOLDER_1!$ARCUS_SUBNET!" "overlays/${ARCUS_OVERLAY_NAME}-local/metallb.yml"

  $KUBECTL apply -f "overlays/${ARCUS_OVERLAY_NAME}-local/metallb.yml"

  if [ $ARCUS_CERT_TYPE = 'production' ]; then
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

  if [ "$ARCUS_ADMIN_EMAIL" = "me@example.com" ]; then
    prompt ARCUS_ADMIN_EMAIL "Please enter your admin email address (or set ARCUS_ADMIN_EMAIL): "
  fi
  echo $ARCUS_ADMIN_EMAIL >$ARCUS_CONFIGDIR/admin.email

  if [ "$ARCUS_DOMAIN_NAME" = "example.com" ]; then
    prompt ARCUS_DOMAIN_NAME "Please enter your domain name (or set ARCUS_DOMAIN_NAME): "
  fi
  echo $ARCUS_DOMAIN_NAME >$ARCUS_CONFIGDIR/domain.name

  if [[ $DEPLOYMENT_TYPE == 'local' && "$ARCUS_SUBNET" == "unconfigured" ]]; then
    echo "Arcus requires a pre-defined subnet for services to be served behind. This subnet must be unallocated (e.g. no IP addresses are used, *and* reserved for static clients)."
    echo "Examples: 192.168.1.200/29, 192.168.1.200-192.168.1.207"
    prompt ARCUS_SUBNET "Please enter your subnet for Arcus services to be exposed on (or set ARCUS_SUBNET): "
    echo $ARCUS_SUBNET >$ARCUS_CONFIGDIR/subnet

  fi

  echo $ARCUS_CERT_TYPE > $ARCUS_CONFIGDIR/cert-issuer

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
  cd $ROOT
  git fetch
  git pull
  cd - >/dev/null
  echo "on $(git rev-parse --abbrev-ref HEAD)"
}

function logs() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: arcuscmd logs <app> [--follow] [--tail=N]"
    exit 1
  fi
  local app=$1
  shift
  $KUBECTL logs --tail=1000 -l app=$app -c $app "$@"
}

function delete() {
  $KUBECTL delete pod -l app=$1
}

function shell_exec() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: arcuscmd shell <app> [command]"
    exit 1
  fi
  local app=$1
  shift
  local pod
  pod=$($KUBECTL get pod -l app=$app -o name | head -1)
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

function backup_cassandra() {
  DATE=$(date '+%Y-%m-%d_%H-%M-%S')
  $KUBECTL exec cassandra-0 -- /bin/tar zcvf "/data/cassandra-${DATE}.tar.gz" cassandra
  $KUBECTL cp cassandra-0:/data/"cassandra-${DATE}.tar.gz" "cassandra-${DATE}.tar.gz"
  $KUBECTL exec cassandra-0 -- /bin/rm "/data/cassandra-${DATE}.tar.gz"
}

function setup_metrics() {
  $KUBECTL apply -f config/stateful/grafana.yaml
  $KUBECTL apply -f config/deployments/kairosdb.yml
  $KUBECTL apply -f config/deployments/metrics-server.yml
}

function arcus_status() {
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
