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

function install {
   # TODO: separate local/cloud
   retry 6 check_k8

   retry 15 /snap/bin/microk8s.enable dns
   /snap/bin/microk8s.enable storage
   /snap/bin/microk8s.enable istio

   $KUBECTL create namespace cert-manager
   $KUBECTL label namespace cert-manager certmanager.k8s.io/disable-validation=true

   $KUBECTL apply -f https://raw.githubusercontent.com/google/metallb/v0.8.1/manifests/metallb.yaml
   $KUBECTL apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/nginx-0.26.0/deploy/static/mandatory.yaml
   $KUBECTL apply -f https://github.com/jetstack/cert-manager/releases/download/v0.10.1/cert-manager.yaml

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
  ARCUS_ADMIN_EMAIL=$(cat $ARCUS_CONFIGDIR/admin.email)
  ARCUS_DOMAIN_NAME=$(cat $ARCUS_CONFIGDIR/domain.name)
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

 ./kustomize build overlays/local-production-local/ | $KUBECTL apply -f -
}

function configure {
  ARCUS_ADMIN_EMAIL=${ARCUS_ADMIN_EMAIL:-me@example.com}
  ARCUS_DOMAIN_NAME=${ARCUS_DOMAIN_NAME:-example.com}

  if [ "$ARCUS_ADMIN_EMAIL" = "me@example.com" ]; then
    prompt ARCUS_ADMIN_EMAIL "Please enter your admin email address (or set ARCUS_ADMIN_EMAIL): "
  fi
  echo $ARCUS_ADMIN_EMAIL > $ARCUS_CONFIGDIR/admin.email

  if [ "$ARCUS_DOMAIN_NAME" = "example.com" ]; then
    prompt ARCUS_DOMAIN_NAME "Please enter your domain name (or set ARCUS_DOMAIN_NAME): "
  fi
  echo $ARCUS_DOMAIN_NAME > $ARCUS_CONFIGDIR/domain.name
}

function update {
  cd $ROOT
  git fetch
  git pull
  cd - >/dev/null
  echo "on $(git rev-parse --abbrev-ref HEAD)"
}
