# shellcheck shell=bash
# Deployment and application management functions

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

  if [[ "${ARCUS_CERT_SOLVER:-http}" == "dns" ]]; then
    cp config/templates/cert-provider-dns.yaml "overlays/${ARCUS_OVERLAY_NAME}-local/cert-provider.yaml"
    sed -i "s!PLACEHOLDER_EMAIL!${ARCUS_ADMIN_EMAIL}!" "overlays/${ARCUS_OVERLAY_NAME}-local/cert-provider.yaml"
    sed -i "s!PLACEHOLDER_ROUTE53_REGION!${ARCUS_ROUTE53_REGION}!" "overlays/${ARCUS_OVERLAY_NAME}-local/cert-provider.yaml"
    sed -i "s!PLACEHOLDER_ROUTE53_ZONE_ID!${ARCUS_ROUTE53_ZONE_ID}!" "overlays/${ARCUS_OVERLAY_NAME}-local/cert-provider.yaml"
  else
    sed -i "s/me@example.com/$ARCUS_ADMIN_EMAIL/" "overlays/${ARCUS_OVERLAY_NAME}-local/cert-provider.yaml"
  fi

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

  if [[ "${ARCUS_CERT_SOLVER:-http}" == "dns" ]]; then
    $KUBECTL create secret generic route53-credentials \
      --namespace cert-manager \
      --from-file=access-key-id=secret/route53-access-key-id \
      --from-file=secret-access-key=secret/route53-secret-access-key \
      --dry-run=client -o yaml | $KUBECTL apply -f - > /dev/null
  fi

  $KUBECTL delete configmap extrafiles --ignore-not-found > /dev/null
  $KUBECTL create configmap extrafiles --from-file config/extrafiles > /dev/null

  $KUBECTL create secret generic shared --from-file secret/ --dry-run=client -o yaml | $KUBECTL apply -f - > /dev/null

  # Show what would change before applying.
  # kubectl diff exits 0 = no diff, 1 = has diff, >1 = error.
  local diff_exit=0
  $KUBECTL diff -k "overlays/${ARCUS_OVERLAY_NAME}-local" 2>/dev/null || diff_exit=$?
  if [[ $diff_exit -eq 0 ]]; then
    echo "No changes to apply."
  else
    $KUBECTL apply -k "overlays/${ARCUS_OVERLAY_NAME}-local"
  fi

  mkdir -p "$ROOT/.cache"
  git -C "$ROOT" rev-parse HEAD > "$ROOT/.cache/last-applied-rev"
}

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

function runmodelmanager() {
  $KUBECTL delete job modelmanager-platform modelmanager-history modelmanager-video --ignore-not-found
  $KUBECTL apply -f config/jobs/
}
