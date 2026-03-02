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
  local arcus_tunable="overlays/${ARCUS_OVERLAY_NAME}-local/arcus-config-tunable.yaml"
  local cluster_tunable="overlays/${ARCUS_OVERLAY_NAME}-local/cluster-config-tunable.yaml"
  local saved_arcus_tunable="" saved_cluster_tunable=""
  # Check .yaml first, fall back to .yml for nodes that haven't been migrated yet
  if [[ -f "$arcus_tunable" ]]; then
    saved_arcus_tunable=$(cat "$arcus_tunable")
  elif [[ -f "${arcus_tunable%.yaml}.yml" ]]; then
    saved_arcus_tunable=$(cat "${arcus_tunable%.yaml}.yml")
  fi
  if [[ -f "$cluster_tunable" ]]; then
    saved_cluster_tunable=$(cat "$cluster_tunable")
  elif [[ -f "${cluster_tunable%.yaml}.yml" ]]; then
    saved_cluster_tunable=$(cat "${cluster_tunable%.yaml}.yml")
  fi

  cp -r "overlays/${ARCUS_OVERLAY_NAME}/"* "overlays/${ARCUS_OVERLAY_NAME}-local/"

  # Restore tunable files if user had customized them
  [[ -n "$saved_arcus_tunable" ]] && echo "$saved_arcus_tunable" > "$arcus_tunable"
  [[ -n "$saved_cluster_tunable" ]] && echo "$saved_cluster_tunable" > "$cluster_tunable"

  # Clean up old .yml tunables after migration
  rm -f "overlays/${ARCUS_OVERLAY_NAME}-local/arcus-config-tunable.yml" \
        "overlays/${ARCUS_OVERLAY_NAME}-local/cluster-config-tunable.yml"

  if [[ "${ARCUS_CERT_SOLVER:-http}" == "dns" ]]; then
    cp config/templates/cert-provider-dns.yaml "overlays/${ARCUS_OVERLAY_NAME}-local/cert-provider.yaml"
    sed -i "s!PLACEHOLDER_EMAIL!${ARCUS_ADMIN_EMAIL}!" "overlays/${ARCUS_OVERLAY_NAME}-local/cert-provider.yaml"
    sed -i "s!PLACEHOLDER_ROUTE53_REGION!${ARCUS_ROUTE53_REGION}!" "overlays/${ARCUS_OVERLAY_NAME}-local/cert-provider.yaml"
    sed -i "s!PLACEHOLDER_ROUTE53_ZONE_ID!${ARCUS_ROUTE53_ZONE_ID}!" "overlays/${ARCUS_OVERLAY_NAME}-local/cert-provider.yaml"
  else
    sed -i "s/me@example.com/$ARCUS_ADMIN_EMAIL/" "overlays/${ARCUS_OVERLAY_NAME}-local/cert-provider.yaml"
  fi

  cp config/configmaps/arcus-config.yaml "overlays/${ARCUS_OVERLAY_NAME}-local/shared-config.yaml"
  sed -i "s/arcussmarthome.com/$ARCUS_DOMAIN_NAME/g" "overlays/${ARCUS_OVERLAY_NAME}-local/shared-config.yaml"

  cp config/configmaps/cluster-config.yaml "overlays/${ARCUS_OVERLAY_NAME}-local/cluster-config.yaml"

  if [[ -n "${ARCUS_CASSANDRA_HOST-}" ]]; then
    sed -i "s!cassandra.default.svc.cluster.local!${ARCUS_CASSANDRA_HOST}!g" "overlays/${ARCUS_OVERLAY_NAME}-local/cluster-config.yaml"
  fi
  if [[ -n "${ARCUS_ZOOKEEPER_HOST-}" ]]; then
    sed -i "s!zookeeper-service.default.svc.cluster.local:2181!${ARCUS_ZOOKEEPER_HOST}!g" "overlays/${ARCUS_OVERLAY_NAME}-local/cluster-config.yaml"
  fi
  if [[ -n "${ARCUS_KAFKA_HOST-}" ]]; then
    sed -i "s!kafka-service.default.svc.cluster.local:9092!${ARCUS_KAFKA_HOST}!g" "overlays/${ARCUS_OVERLAY_NAME}-local/cluster-config.yaml"
  fi

  cp config/service/ui-service-ingress.yaml "overlays/${ARCUS_OVERLAY_NAME}-local/"ui-service-ingress.yaml
  sed -i "s/arcussmarthome.com/$ARCUS_DOMAIN_NAME/" "overlays/${ARCUS_OVERLAY_NAME}-local/ui-service-ingress.yaml"

  if [[ "${ARCUS_METALLB:-}" == "yes" ]]; then
    cp config/templates/metallb.yaml "overlays/${ARCUS_OVERLAY_NAME}-local/metallb.yaml"
    sed -i "s!PLACEHOLDER_1!$ARCUS_SUBNET!" "overlays/${ARCUS_OVERLAY_NAME}-local/metallb.yaml"
    $KUBECTL apply -f "overlays/${ARCUS_OVERLAY_NAME}-local/metallb.yaml"
  fi

  if [[ -n "${ARCUS_PROXY_REAL_IP-}" ]]; then
    cp config/nginx-proxy.yaml "overlays/${ARCUS_OVERLAY_NAME}-local/nginx-proxy.yaml"
    sed -i "s!PLACEHOLDER_PROXY_IP!${ARCUS_PROXY_REAL_IP}!" "overlays/${ARCUS_OVERLAY_NAME}-local/nginx-proxy.yaml"
    $KUBECTL apply -f "overlays/${ARCUS_OVERLAY_NAME}-local/nginx-proxy.yaml"
  fi

  if [[ -n "${ARCUS_ADMIN_DOMAIN-}" ]]; then
    # Only create a separate admin ingress when the admin domain is NOT already
    # covered by ui-service-ingress (which includes admin.$ARCUS_DOMAIN_NAME).
    if [[ "${ARCUS_ADMIN_DOMAIN}" != "admin.${ARCUS_DOMAIN_NAME}" ]]; then
      cp config/service/dc-admin-ingress.yaml "overlays/${ARCUS_OVERLAY_NAME}-local/dc-admin-ingress.yaml"
      sed -i "s!PLACEHOLDER_ADMIN_DOMAIN!${ARCUS_ADMIN_DOMAIN}!" "overlays/${ARCUS_OVERLAY_NAME}-local/dc-admin-ingress.yaml"
      $KUBECTL apply -f "overlays/${ARCUS_OVERLAY_NAME}-local/dc-admin-ingress.yaml"
    fi
  fi

  cp config/stateful/grafana.yaml "overlays/${ARCUS_OVERLAY_NAME}-local/grafana.yaml"
  if [[ -n "${ARCUS_ADMIN_DOMAIN-}" ]]; then
    sed -i "s!PLACEHOLDER_ADMIN_DOMAIN!${ARCUS_ADMIN_DOMAIN}!" "overlays/${ARCUS_OVERLAY_NAME}-local/grafana.yaml"
  else
    sed -i "s!PLACEHOLDER_ADMIN_DOMAIN!localhost!" "overlays/${ARCUS_OVERLAY_NAME}-local/grafana.yaml"
  fi

  if [[ "${ARCUS_CERT_TYPE:-}" == 'production' ]]; then
    sed -i 's/letsencrypt-staging/letsencrypt-production/g' "overlays/${ARCUS_OVERLAY_NAME}-local/ui-service-ingress.yaml"
    sed -i 's/nginx-staging-tls/nginx-production-tls/g' "overlays/${ARCUS_OVERLAY_NAME}-local/ui-service-ingress.yaml"
  fi

  if [[ "${ARCUS_CERT_SOLVER:-http}" == "dns" ]]; then
    $KUBECTL create secret generic route53-credentials \
      --namespace cert-manager \
      --from-file=access-key-id=secret/route53-access-key-id \
      --from-file=secret-access-key=secret/route53-secret-access-key \
      --dry-run=client -o yaml | $KUBECTL apply -f - > /dev/null
  fi

  $KUBECTL delete configmap extrafiles --ignore-not-found > /dev/null
  $KUBECTL create configmap extrafiles \
    --from-file=firmware.xml=config/extrafiles/firmware.xml \
    --from-file=logback.xml=config/extrafiles/logback.xml > /dev/null

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

  if [[ ! -d "overlays/${ARCUS_OVERLAY_NAME}-local" ]]; then
    echo "Error: overlay 'overlays/${ARCUS_OVERLAY_NAME}-local' not found."
    echo "Run './arcuscmd.sh apply' before deploying."
    return 1
  fi

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

  local mode="Rolling restart"
  [[ $pull -eq 1 ]] && mode="Pull and restart"
  _notify_start "$mode: $targets"

  local _deploy_current_app=""
  trap 'echo ""; [[ -n "$_deploy_current_app" ]] && echo "Interrupted during: ${_deploy_current_app}"; _notify_failure "$mode interrupted"; trap - INT; kill -INT $$' INT

  if [[ $pull -eq 1 ]]; then
    for app in $targets; do
      _deploy_current_app="pulling $app"
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
    if ! $KUBECTL get deployment/"$app" &>/dev/null; then
      echo "Skipping ${app} (not deployed)."
      continue
    fi
    _deploy_current_app="restarting $app"
    echo "Restarting ${app}..."
    $KUBECTL rollout restart deployment/"$app"
    $KUBECTL rollout status deployment/"$app" --timeout=120s
    echo "${app} ready."
  done

  trap - INT
  _notify_success "$mode complete: $targets"
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
  echo "hub-bridge api-bridge client-bridge" | tr ' ' '\n' | xargs -P 2 -I{} "$KUBECTL" delete pod -l app={} --ignore-not-found 2>/dev/null
  echo "driver-services rule-service scheduler-service" | tr ' ' '\n' | xargs -P 2 -I{} "$KUBECTL" delete pod -l app={} --ignore-not-found 2>/dev/null
  echo "alarm-service subsystem-service history-service ivr-callback-server notification-services platform-services ui-server" | tr ' ' '\n' | xargs -P 3 -I{} "$KUBECTL" delete pod -l app={} --ignore-not-found 2>/dev/null
}

function useprodcert() {
  load
  echo 'production' > "$ARCUS_CONFIGDIR/cert-issuer"
  local ingress="overlays/${ARCUS_OVERLAY_NAME}-local/ui-service-ingress.yaml"
  # Fall back to .yml for nodes that haven't re-run apply since the rename
  if [[ ! -f "$ingress" && -f "${ingress%.yaml}.yml" ]]; then
    ingress="${ingress%.yaml}.yml"
  fi
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

  # Annotate hub-keystore with source resourceVersion so the renewal CronJob
  # can detect when the certificate has been rotated.
  local source_rv
  source_rv=$($KUBECTL get secret nginx-production-tls -o jsonpath='{.metadata.resourceVersion}')
  $KUBECTL annotate secret hub-keystore "arcus.io/source-resource-version=${source_rv}" --overwrite

  rm -rf converted
  echo "Hub keystore created with production certificate and trust store."

  echo "Restarting hub-bridge..."
  $KUBECTL rollout restart deployment/hub-bridge
  $KUBECTL rollout status deployment/hub-bridge --timeout=120s
  echo "hub-bridge restarted."
}

function runmodelmanager() {
  $KUBECTL delete job modelmanager-platform modelmanager-history modelmanager-video --ignore-not-found
  $KUBECTL apply -f config/jobs/
}
