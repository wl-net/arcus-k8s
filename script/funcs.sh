# shared functions

function updatehubkeystore {
        echo "Creating hub-keystore..."
	mkdir -p converted
	KUBE_EDITOR=cat $KUBECTL edit secret nginx-production-tls 2>/dev/null | grep tls.key | awk '{print $2}' | base64 -d > converted/orig.key
	KUBE_EDITOR=cat $KUBECTL edit secret nginx-production-tls 2>/dev/null | grep tls.crt | awk '{print $2}' | base64 -d > converted/tls.crt

	openssl pkcs8 -in converted/orig.key -topk8 -nocrypt -out converted/tls.key
	rm converted/orig.key

	set +e
	$KUBECTL delete secret hub-keystore
	$KUBECTL create secret generic truststore --from-file irisbylowes/truststore.jks
	set -e
	$KUBECTL create secret tls hub-keystore --cert converted/tls.crt --key converted/tls.key

	rm -rf converted
	echo "All done. Goodbye!"
}

function useprodcert {
	sed -i 's/letsencrypt-staging/letsencrypt-production/g' overlays/local-production-local/ui-service-ingress.yml
	sed -i 's/nginx-staging-tls/nginx-production-tls/g' overlays/local-production-local/ui-service-ingress.yml
	$KUBECTL apply -f overlays/local-production-local/ui-service-ingress.yml
}

function runmodelmanager {
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

function provision {
  echo "Setting up cassandra and kafka"
  retry 10 $KUBECTL exec cassandra-0 --stdin --tty -- '/bin/sh' '-c' 'CASSANDRA_KEYSPACE=production CASSANDRA_REPLICATION=1 CASSANDRA_HOSTNAME=localhost /usr/bin/cassandra-provision'
  retry 10 $KUBECTL exec kafka-0 --stdin --tty -- '/bin/sh' '-c' 'KAFKA_REPLICATION=1 KAFKAOPS_REPLICATION=1 kafka-cmd setup'
}

APPS='alarm-service client-bridge driver-services subsystem-service history-service hub-bridge ipcd-bridge ivr-callback-server metrics-server notification-services platform-services rule-service scheduler-service ui-server'
function deployfast {
	$KUBECTL delete pod -l app=cassandra
	$KUBECTL delete pod -l app=zookeeper
	$KUBECTL delete pod -l app=kafka
	for app in $APPS; do
            $KUBECTL delete pod -l app=$app
	    sleep 5
	done
}

# Setup MicroK8s for local.
function setupmicrok8s {
  PKGMGR=apt-get # TODO
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

function install {
  if [[ ! -e kustomize ]]; then
    . kustomize-install.sh
  fi

  set +e
  $KUBECTL create namespace cert-manager 2>/dev/null
  $KUBECTL label namespace cert-manager certmanager.k8s.io/disable-validation=true --overwrite=true
  set -e

  # TODO: only re-install metallb if this is a local deployment
  $KUBECTL apply -f https://raw.githubusercontent.com/google/metallb/$METALLB_VERSION/manifests/metallb.yaml
  $KUBECTL apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/nginx-$NGINX_VERSION/deploy/static/mandatory.yaml
  $KUBECTL apply -f https://github.com/jetstack/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml

  $KUBECTL apply -f overlays/local-production-local/metallb.yml
}

function info {
  load
  IPADDRESS=$($KUBECTL describe service -n ingress-nginx | grep 'LoadBalancer Ingress:' | awk '{print $3}')
  HUB_IPADDRESS=$($KUBECTL describe service hub-bridge-service | grep 'LoadBalancer Ingress:' | awk '{print $3}')

  echo "DNS -> IP/Port Mappings: "
  echo "If these IP addresses are private, you are responsible for setting up port forwarding"
  echo "${ARCUS_DOMAIN_NAME}:80 -> $IPADDRESS:80"
  echo "${ARCUS_DOMAIN_NAME}:443 -> $IPADDRESS:443"
  echo "client.${ARCUS_DOMAIN_NAME}:443 -> $IPADDRESS:443"
  echo "static.${ARCUS_DOMAIN_NAME}:443 -> $IPADDRESS:443"
  echo "ipcd.${ARCUS_DOMAIN_NAME}:443 -> $IPADDRESS:443"
  echo "admin.${ARCUS_DOMAIN_NAME}:443 -> $IPADDRESS:443"
  echo "hub.${ARCUS_DOMAIN_NAME}:443 -> $IPADDRESS:443"
}

function load {
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
  fi
}

function apply {
  # Apply the configuration
  load

  mkdir -p overlays/local-production-local
  cp -r overlays/local-production/* overlays/local-production-local

  sed -i "s/me@example.com/$ARCUS_ADMIN_EMAIL/" overlays/local-production-local/cert-provider.yaml

  cp config/shared-config/config.yml overlays/local-production-local/shared-config.yaml
  sed -i "s/arcussmarthome.com/$ARCUS_DOMAIN_NAME/" overlays/local-production-local/shared-config.yaml

  cp config/service/ui-service-ingress.yml overlays/local-production-local/ui-service-ingress.yml
  sed -i "s/arcussmarthome.com/$ARCUS_DOMAIN_NAME/" overlays/local-production-local/ui-service-ingress.yml

  cp localk8/metallb.yml overlays/local-production-local/metallb.yml
  sed -i "s!PLACEHOLDER_1!$ARCUS_SUBNET!" overlays/local-production-local/metallb.yml

  $KUBECTL apply -f config/certprovider/

 ./kustomize build overlays/local-production-local/ | $KUBECTL apply -f -
}

function configure {
  load
  ARCUS_ADMIN_EMAIL=${ARCUS_ADMIN_EMAIL:-me@example.com}
  ARCUS_DOMAIN_NAME=${ARCUS_DOMAIN_NAME:-example.com}
  ARCUS_SUBNET=${ARCUS_SUBNET:-unconfigured}

  if [ "$ARCUS_ADMIN_EMAIL" = "me@example.com" ]; then
    prompt ARCUS_ADMIN_EMAIL "Please enter your admin email address (or set ARCUS_ADMIN_EMAIL): "
  fi
  echo $ARCUS_ADMIN_EMAIL > $ARCUS_CONFIGDIR/admin.email

  if [ "$ARCUS_DOMAIN_NAME" = "example.com" ]; then
    prompt ARCUS_DOMAIN_NAME "Please enter your domain name (or set ARCUS_DOMAIN_NAME): "
  fi
  echo $ARCUS_DOMAIN_NAME > $ARCUS_CONFIGDIR/domain.name


  if [[ $DEPLOYMENT_TYPE = 'local' &&  "$ARCUS_SUBNET" = "unconfigured" ]]; then
    echo "Arcus requires a pre-defined subnet for services to be served behind. This subnet must be unallocated (e.g. no IP addresses are used, *and* reserved for static clients)."
    echo "Examples: 192.168.1.200/29, 192.168.1.200-192.168.1.207"
    prompt ARCUS_SUBNET "Please enter your subnet for Arcus services to be exposed on (or set ARCUS_SUBNET): "
    echo $ARCUS_SUBNET > $ARCUS_CONFIGDIR/subnet

  fi
}

function update {
  cd $ROOT
  git fetch
  git pull
  cd - >/dev/null
  echo "on $(git rev-parse --abbrev-ref HEAD)"
}

function logs {
  set +u
  $KUBECTL logs --tail=10000 -l app=$2 -c $2 $3
  set -u
}

