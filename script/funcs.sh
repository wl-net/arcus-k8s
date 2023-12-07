# shared functions

function updatehubkeystore() {
  echo "Creating hub-keystore..."
  mkdir -p converted
  KUBE_EDITOR=cat $KUBECTL edit secret nginx-production-tls 2>/dev/null | grep tls.key | awk '{print $2}' | head -n 1 | base64 -d >converted/orig.key
  KUBE_EDITOR=cat $KUBECTL edit secret nginx-production-tls 2>/dev/null | grep tls.crt | awk '{print $2}' | head -n 1 | base64 -d >converted/tls.crt

  openssl pkcs8 -in converted/orig.key -topk8 -nocrypt -out converted/tls.key
  rm converted/orig.key

  set +e
  $KUBECTL delete secret hub-keystore
  $KUBECTL create secret generic truststore --from-file irisbylowes/truststore.jks
  set -e
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
  $KUBECTL delete pod -l app=cassandra &
  $KUBECTL delete pod -l app=zookeeper &
  $KUBECTL delete pod -l app=kafka &

  for app in $APPS; do
    $KUBECTL delete pod -l app=$app &
    sleep 1
  done

  wait
}

# Setup MicroK8s for local.
function setup_microk8s() {
  if [ -f /etc/debian_version ]; then
    PKGMGR=apt-get
  elif [ -f /etc/redhat-release ]; then
    PKGMGR=dnf
  fi
  echo "Installing snap..."
  sudo $PKGMGR install snapd curl -y
  sudo snap install microk8s --classic

  retry 6 check_k8

  retry 15 /snap/bin/microk8s.enable dns
  /snap/bin/microk8s.enable storage
  echo y | /snap/bin/microk8s.enable istio

  # metallb needed
  $KUBECTL apply -f https://raw.githubusercontent.com/google/metallb/$METALLB_VERSION/manifests/metallb.yaml

}

function setup_k3s() {
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--no-deploy servicelb --write-kubeconfig-mode 644' sh -
}

function setup_helm() {
  curl https://raw.githubusercontent.com/helm/helm/master/scripts/get | bash
}

function setup_istio() {
  set +e
  $KUBECTL create namespace istio-system
  set -e
  mkdir -p .temp
  cd .temp
  curl -L https://git.io/getLatestIstio | ISTIO_VERSION=1.4.6 sh -
  cd "istio-${ISTIO_VERSION}"
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm template install/kubernetes/helm/istio-init --name istio-init --namespace istio-system | kubectl apply -f -
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm template install/kubernetes/helm/istio --name istio --namespace istio-system --set mixer.telemetry.resources.requests.cpu=100m --set mixer.telemetry.resources.requests.memory=256M --set pilot.resources.requests.cpu=100m --set pilot.resources.requests.memory=512M | kubectl apply -f -
  cd -
  cd .. # leave .temp
}

function install() {
  $KUBECTL label namespace default istio-injection=enabled --overwrite

  local count=$($KUBECTL get apiservice | grep certmanager.k8s.io -c)
  if [[ $count -gt 0 ]]; then
    echo "Removing cert-manager, please see https://docs.cert-manager.io/en/latest/tasks/uninstall/kubernetes.html for more details"
    set +e
    $KUBECTL delete -f https://github.com/jetstack/cert-manager/releases/download/v0.10.1/cert-manager.yaml
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

  # TODO: only re-install metallb if this is a local deployment
  $KUBECTL apply -f https://raw.githubusercontent.com/google/metallb/$METALLB_VERSION/manifests/namespace.yaml
  $KUBECTL apply -f https://raw.githubusercontent.com/google/metallb/$METALLB_VERSION/manifests/metallb.yaml
  $KUBECTL apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v$NGINX_VERSION/deploy/static/provider/baremetal/deploy.yaml
  $KUBECTL apply -f https://github.com/jetstack/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml

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
  set +u
  $KUBECTL logs --tail=10000 -l app=$2 -c $2 $3
  set -u
}

function delete() {
  $KUBECTL delete pod -l app=$2
}

function backup_cassandra() {
  DATE=$(date '+%Y-%m-%d_%H-%M-%S')
  $KUBECTL exec --stdin --tty cassandra-0 /bin/tar zcvf "/data/cassandra-${DATE}.tar.gz" cassandra
  $KUBECTL cp cassandra-0:/data/"cassandra-${DATE}.tar.gz" "cassandra-${DATE}.tar.gz"
  $KUBECTL exec --stdin --tty cassandra-0 /bin/rm "/data/cassandra-${DATE}.tar.gz"
}

function setup_metrics() {
  $KUBECTL apply -f config/stateful/grafana.yaml
  $KUBECTL apply -f config/deployments/kairosdb.yml
  $KUBECTL apply -f config/deployments/metrics-server.yml
}

function arcus_status() {
  $KUBECTL describe statefulset cassandra | grep 'Pods Status'
  $KUBECTL describe statefulset kafka | grep 'Pods Status'
}
