# shellcheck shell=bash
# Deployment and application management functions

# Print a Prometheus file_sd target group labeled datastore=$1 for the
# comma-separated hosts in $3, adding the default port $2 to any host without one.
function _datastore_targets() {
  local name=$1 port=$2 host targets=""
  local -a hosts
  IFS=',' read -ra hosts <<< "$3"
  for host in "${hosts[@]}"; do
    host=${host// /}
    [[ -n "$host" ]] || continue
    [[ "$host" == *:* ]] || host="$host:$port"
    targets+="${targets:+, }\"$host\""
  done
  printf '{"targets": [%s], "labels": {"datastore": "%s"}}' "$targets" "$name"
}

function apply() {
  # Apply the configuration
  load

  if [ ! -d "overlays/${ARCUS_OVERLAY_NAME}" ] && [ "${ARCUS_OVERLAY_NAME}" != 'local-production-local' ]; then
    echo "Could not find overlay ${ARCUS_OVERLAY_NAME}"
    exit 1
  fi

  local missing=()
  [[ -n "${ARCUS_CASSANDRA_HOST-}" ]] || missing+=(cassandra-host)
  [[ -n "${ARCUS_KAFKA_HOST-}" ]] || missing+=(kafka-host)
  [[ -n "${ARCUS_ZOOKEEPER_HOST-}" ]] || missing+=(zookeeper-host)
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing .config/ ${missing[*]}. Cassandra, Kafka and ZooKeeper run outside the cluster;"
    echo "run './arcuscmd.sh configure' or write their hosts to .config/ directly."
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

  # Clean up stale ingress-nginx overlay from the Traefik migration
  rm -f "overlays/${ARCUS_OVERLAY_NAME}-local/nginx-proxy.yaml"

  # Clean up the in-cluster datastore manifests, which were removed from the overlay
  rm -f "overlays/${ARCUS_OVERLAY_NAME}-local/"{cassandra,kafka,zookeeper}.yaml \
        "overlays/${ARCUS_OVERLAY_NAME}-local/zookeeper.yml"

  # Apply Cassandra DC overrides from .config/ into the cluster tunable
  if [[ -n "${ARCUS_CASSANDRA_DC-}" ]]; then
    sed -i "s/CASSANDRA_LOADBALANCINGPOLICY: roundrobin$/CASSANDRA_LOADBALANCINGPOLICY: roundrobindc/" "$cluster_tunable"
    sed -i "s/CASSANDRA_LOCAL_DATACENTER: .*/CASSANDRA_LOCAL_DATACENTER: '${ARCUS_CASSANDRA_DC}'/" "$cluster_tunable"
    local history_dc="${ARCUS_CASSANDRA_HISTORY_DC:-$ARCUS_CASSANDRA_DC}"
    sed -i "s/CASSANDRA_HISTORY_LOCAL_DATACENTER: .*/CASSANDRA_HISTORY_LOCAL_DATACENTER: '${history_dc}'/" "$cluster_tunable"
  fi
  if [[ -n "${ARCUS_KAFKA_CLIENT_RACK-}" ]]; then
    sed -i "s/KAFKA_CLIENT_RACK: .*/KAFKA_CLIENT_RACK: '${ARCUS_KAFKA_CLIENT_RACK}'/" "$cluster_tunable"
  fi

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
  sed -i -e "s!PLACEHOLDER_CASSANDRA_HOST!${ARCUS_CASSANDRA_HOST}!g" \
         -e "s!PLACEHOLDER_KAFKA_HOST!${ARCUS_KAFKA_HOST}!g" \
         -e "s!PLACEHOLDER_ZOOKEEPER_HOST!${ARCUS_ZOOKEEPER_HOST}!g" \
         "overlays/${ARCUS_OVERLAY_NAME}-local/cluster-config.yaml"

  cp config/service/ui-service-ingress.yaml "overlays/${ARCUS_OVERLAY_NAME}-local/"ui-service-ingress.yaml
  sed -i "s/arcussmarthome.com/$ARCUS_DOMAIN_NAME/" "overlays/${ARCUS_OVERLAY_NAME}-local/ui-service-ingress.yaml"

  if [[ "${ARCUS_METALLB:-}" == "yes" ]]; then
    cp config/templates/metallb.yaml "overlays/${ARCUS_OVERLAY_NAME}-local/metallb.yaml"
    sed -i "s!PLACEHOLDER_1!$ARCUS_SUBNET!" "overlays/${ARCUS_OVERLAY_NAME}-local/metallb.yaml"
    $KUBECTL apply -f "overlays/${ARCUS_OVERLAY_NAME}-local/metallb.yaml"
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

  # TCP check targets for the blackbox-datastores Prometheus job. ZooKeeper's
  # connect string may end in a chroot (host:2181/arcus), which isn't part of a host.
  local targets="overlays/${ARCUS_OVERLAY_NAME}-local/datastores.json"
  printf '[%s,\n %s,\n %s]\n' \
    "$(_datastore_targets cassandra 9042 "$ARCUS_CASSANDRA_HOST")" \
    "$(_datastore_targets kafka 9092 "$ARCUS_KAFKA_HOST")" \
    "$(_datastore_targets zookeeper 2181 "${ARCUS_ZOOKEEPER_HOST%%/*}")" > "$targets"
  $KUBECTL create configmap prometheus-targets --from-file=datastores.json="$targets" \
    --dry-run=client -o yaml | $KUBECTL apply -f - > /dev/null

  ensure_grafana_renderer_token
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

  # Remove the ingress-nginx IngressClass left over from pre-Traefik days.
  $KUBECTL delete ingressclass nginx --ignore-not-found > /dev/null

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
  local workers=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pull)
        pull=1
        shift
        ;;
      -w|--workers)
        if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -lt 1 ]]; then
          echo "Error: --workers requires a positive integer argument"
          return 1
        fi
        workers="$2"
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done

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

  if [[ $workers -eq 1 ]]; then
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
  else
    echo "Deploying with ${workers} workers..."
    local pids=()
    local running=0
    local failed=0

    for app in $targets; do
      if ! $KUBECTL get deployment/"$app" &>/dev/null; then
        echo "Skipping ${app} (not deployed)."
        continue
      fi

      # Wait for a worker slot to free up
      while [[ $running -ge $workers ]]; do
        local new_pids=()
        for pid in "${pids[@]}"; do
          if kill -0 "$pid" 2>/dev/null; then
            new_pids+=("$pid")
          else
            wait "$pid" || failed=$((failed + 1))
            running=$((running - 1))
          fi
        done
        pids=("${new_pids[@]}")
        [[ $running -ge $workers ]] && sleep 1
      done

      (
        echo "Restarting ${app}..."
        $KUBECTL rollout restart deployment/"$app"
        $KUBECTL rollout status deployment/"$app" --timeout=120s
        echo "${app} ready."
      ) &
      pids+=($!)
      running=$((running + 1))
    done

    # Wait for remaining workers
    for pid in "${pids[@]}"; do
      wait "$pid" || failed=$((failed + 1))
    done

    if [[ $failed -gt 0 ]]; then
      trap - INT
      _notify_failure "$mode failed: ${failed} service(s) had errors"
      return 1
    fi
  fi

  trap - INT
  _notify_success "$mode complete: $targets"
}

function killallpods() {
  load
  if [[ "${ARCUS_OVERLAY_NAME:-}" == *cluster* ]]; then
    echo "WARNING: This will delete every Arcus pod at once, taking all services down until they restart."
    echo "Consider using './arcuscmd.sh deploy' for a safe rolling restart instead."
    echo ""
    local confirm
    prompt confirm "Are you sure you want to continue? [yes/no]:"
    if [[ "$confirm" != "yes" ]]; then
      echo "Aborted."
      return 0
    fi
  fi
  # Bridges, then the core services, then everything else in APPS (so new
  # services are included without editing this list)
  local bridges="hub-bridge api-bridge client-bridge"
  local core="driver-services rule-service scheduler-service"
  local rest="" app
  for app in $APPS static-server; do
    [[ " $bridges $core " == *" $app "* ]] || rest+="$app "
  done
  echo "$bridges" | tr ' ' '\n' | xargs -P 2 -I{} "$KUBECTL" delete pod -l app={} --ignore-not-found 2>/dev/null
  echo "$core" | tr ' ' '\n' | xargs -P 2 -I{} "$KUBECTL" delete pod -l app={} --ignore-not-found 2>/dev/null
  echo "${rest% }" | tr ' ' '\n' | xargs -P 3 -I{} "$KUBECTL" delete pod -l app={} --ignore-not-found 2>/dev/null
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

function renewcert() {
  local certs=("$@")
  if [[ ${#certs[@]} -eq 0 ]]; then
    mapfile -t certs < <($KUBECTL get certificates -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  fi
  if [[ ${#certs[@]} -eq 0 ]]; then
    echo "Error: no certificates found."
    exit 1
  fi

  local cert i op path now
  local -a conditions
  local -A revisions=()
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for cert in "${certs[@]}"; do
    if ! revisions[$cert]=$($KUBECTL get certificate "$cert" -o jsonpath='{.status.revision}' 2>/dev/null); then
      echo "Error: certificate $cert not found."
      exit 1
    fi

    # Same mechanism as 'cmctl renew': cert-manager re-issues when the
    # Issuing condition is set to True. Replace an existing (failed) Issuing
    # condition in place, since conditions are keyed by type.
    op=add
    path=/status/conditions/-
    mapfile -t conditions < <($KUBECTL get certificate "$cert" -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}')
    for i in "${!conditions[@]}"; do
      case "${conditions[$i]}" in
      Issuing=True) op='' ;;
      Issuing=*) op=replace path="/status/conditions/$i" ;;
      esac
    done
    if [[ -z "$op" ]]; then
      echo "$cert: issuance already in progress."
      continue
    fi

    echo "$cert: triggering renewal..."
    $KUBECTL patch certificate "$cert" --subresource status --type json -p "[{\"op\":\"$op\",\"path\":\"$path\",\"value\":{\"type\":\"Issuing\",\"status\":\"True\",\"reason\":\"ManuallyTriggered\",\"message\":\"Certificate re-issuance manually triggered by arcuscmd\",\"lastTransitionTime\":\"$now\"}}]" >/dev/null
  done

  echo "Waiting for cert-manager to issue new certificates (timeout 5m)..."
  local deadline=$((SECONDS + 300)) revision ready
  local -a pending
  while true; do
    pending=()
    for cert in "${certs[@]}"; do
      revision=$($KUBECTL get certificate "$cert" -o jsonpath='{.status.revision}')
      ready=$($KUBECTL get certificate "$cert" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
      if [[ "$revision" == "${revisions[$cert]}" || "$ready" != "True" ]]; then
        pending+=("$cert")
      fi
    done
    if [[ ${#pending[@]} -eq 0 ]]; then
      break
    fi
    if ((SECONDS >= deadline)); then
      echo "Error: timed out waiting for: ${pending[*]}"
      echo "Check progress with '$KUBECTL describe certificate <name>' or './arcuscmd.sh certlogs'."
      exit 1
    fi
    sleep 5
  done
  echo "Certificates renewed: ${certs[*]}"

  # hub-bridge serves its own copy of the production cert; refresh it now
  # rather than waiting for the hub-keystore-renewal CronJob.
  for cert in "${certs[@]}"; do
    if [[ "$cert" == nginx-production-tls ]]; then
      updatehubkeystore
    fi
  done
}

function updatehubkeystore() {
  echo "Creating hub-keystore..."

  if ! $KUBECTL get secret nginx-production-tls &>/dev/null; then
    echo "Error: nginx-production-tls secret not found. Has a production certificate been issued?"
    exit 1
  fi

  # Read the resourceVersion before the data, so a certificate rotated mid-run
  # leaves an older annotation and the renewal CronJob picks it up
  local source_rv
  source_rv=$($KUBECTL get secret nginx-production-tls -o jsonpath='{.metadata.resourceVersion}')

  # Keep the certificate and key in memory so the private key never touches disk
  local cert key
  cert=$($KUBECTL get secret nginx-production-tls -o jsonpath='{.data.tls\.crt}' | base64 -d)

  if ! printf '%s\n' "$cert" | openssl x509 -checkend 0 -noout &>/dev/null; then
    echo "Error: certificate has expired. Renew it before updating the hub keystore."
    exit 1
  fi

  key=$($KUBECTL get secret nginx-production-tls -o jsonpath='{.data.tls\.key}' | base64 -d | openssl pkcs8 -topk8 -nocrypt)

  # Apply over the existing secret rather than delete and recreate, so
  # hub-keystore never goes missing while hub-bridge might mount it
  $KUBECTL create secret generic truststore --from-file util/truststore.jks --dry-run=client -o yaml | $KUBECTL apply -f -
  $KUBECTL create secret tls hub-keystore --cert <(printf '%s\n' "$cert") --key <(printf '%s\n' "$key") \
    --dry-run=client -o yaml | $KUBECTL apply -f -

  # Annotate hub-keystore with source resourceVersion so the renewal CronJob
  # can detect when the certificate has been rotated.
  $KUBECTL annotate secret hub-keystore "arcus.io/source-resource-version=${source_rv}" --overwrite

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
