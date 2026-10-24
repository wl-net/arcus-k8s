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

# Print Prometheus file_sd target groups for the comma-separated admin domains of
# the other datacenters in $1: each one's Grafana health endpoint, labeled peer=<domain>.
function _peer_targets() {
  local domain groups=""
  local -a domains
  IFS=',' read -ra domains <<< "$1"
  for domain in "${domains[@]}"; do
    domain=${domain// /}
    [[ -n "$domain" ]] || continue
    groups+="${groups:+,$'\n' }{\"targets\": [\"https://$domain/api/health\"], \"labels\": {\"peer\": \"$domain\"}}"
  done
  printf '[%s]\n' "$groups"
}

# Print Prometheus file_sd target groups for this cluster's public URLs on domain $1
# (and the admin domain $2 if there is one), resolved through public DNS as a user would.
function _public_targets() {
  local domain=$1 admin=$2
  local targets="\"https://$domain/\", \"https://client.$domain/\", \"https://static.$domain/\""
  [[ -z "$admin" ]] || targets+=", \"https://$admin/api/health\""
  printf '[{"targets": [%s], "labels": {}}]\n' "$targets"
}

# Print Prometheus file_sd target groups that reach each other datacenter's public
# services at that datacenter: for the comma-separated peer admin domains in $1, the
# peer's own address with the public hostnames of domain $2 sent as Host header and
# TLS server name (the blackbox exporter's hostname parameter), labeled
# peer=<admin domain> and hostname=<public hostname>.
function _peer_public_targets() {
  local peer host groups=""
  local -a admin_domains
  IFS=',' read -ra admin_domains <<< "$1"
  for peer in "${admin_domains[@]}"; do
    peer=${peer// /}
    [[ -n "$peer" ]] || continue
    for host in "$2" "client.$2" "static.$2"; do
      groups+="${groups:+,$'\n' }{\"targets\": [\"https://$peer/\"], \"labels\": {\"peer\": \"$peer\", \"hostname\": \"$host\"}}"
    done
  done
  printf '[%s]\n' "$groups"
}

# Write config/grafana/alerting.yaml to $1 with its PLACEHOLDER_* tokens filled in:
# PLACEHOLDER_EXPECTED_HUBS from .config/expected-hubs (default 4), the most hubs
# Unexpected Hub Connections allows, and PLACEHOLDER_RUNBOOK_REF, the commit the
# runbook links name, so they show the runbook that matches the deployed rule
# even after a rollback (master when this isn't a git checkout).
function _render_alert_rules() {
  local hubs="${ARCUS_EXPECTED_HUBS:-4}" ref
  if ! [[ "$hubs" =~ ^[0-9]+$ ]]; then
    echo "Error: .config/expected-hubs must be a whole number, not '${hubs}'."
    return 1
  fi
  ref=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null) || ref=master
  sed -e "s/PLACEHOLDER_EXPECTED_HUBS/${hubs}/g" -e "s/PLACEHOLDER_RUNBOOK_REF/${ref}/g" \
    "$ROOT/config/grafana/alerting.yaml" > "$1"
}

# Print Grafana alerting provisioning for the contact points in .config/alert-*:
# a Discord contact point, a Pushover one, and a notification policy that sends
# every alert to Discord and critical ones to Pushover as well (with only
# Pushover, the rest go there quietly). With neither configured, prints a file
# that provisions nothing, so a policy set up by hand in Grafana is left alone.
function _grafana_notifications() {
  local discord="${ARCUS_ALERT_DISCORD_WEBHOOK-}"
  local user="${ARCUS_ALERT_PUSHOVER_USER_KEY-}" token="${ARCUS_ALERT_PUSHOVER_API_TOKEN-}"
  if [[ -n "$user" && -z "$token" || -z "$user" && -n "$token" ]]; then
    echo "Error: .config/alert-pushover-user-key and alert-pushover-api-token are needed together." >&2
    return 1
  fi
  echo 'apiVersion: 1'
  if [[ -z "$discord" && -z "$user" ]]; then
    return 0
  fi
  echo 'contactPoints:'
  if [[ -n "$discord" ]]; then
    cat <<EOF
- orgId: 1
  name: arcus-discord
  receivers:
  - uid: arcus-discord
    type: discord
    settings:
      url: '${discord}'
      title: '{{ template "arcus.title" . }}'
      message: '{{ template "arcus.message" . }}'
EOF
  fi
  if [[ -n "$user" ]]; then
    # Critical alerts at high priority, their resolutions and everything else
    # (when there is no Discord) at the quiet ones
    local name priority ok_priority
    for name in arcus-pushover:1:0 arcus-pushover-quiet:-1:-1; do
      IFS=: read -r name priority ok_priority <<< "$name"
      cat <<EOF
- orgId: 1
  name: ${name}
  receivers:
  - uid: ${name}
    type: pushover
    settings:
      userKey: '${user}'
      apiToken: '${token}'
      priority: '${priority}'
      okPriority: '${ok_priority}'
      title: '{{ template "arcus.title" . }}'
      message: '{{ template "arcus.text" . }}'
EOF
    done
  fi
  local default_receiver=arcus-discord
  [[ -n "$discord" ]] || default_receiver=arcus-pushover-quiet
  cat <<EOF
policies:
- orgId: 1
  receiver: ${default_receiver}
  group_by: [alertname]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
EOF
  if [[ -n "$user" ]]; then
    cat <<EOF
  - receiver: arcus-pushover
    object_matchers:
    - [severity, =, critical]
    repeat_interval: 2h
    continue: true
EOF
  fi
  if [[ -n "$discord" ]]; then
    cat <<EOF
  - receiver: arcus-discord
    object_matchers:
    - [severity, =~, .+]
EOF
  fi
}

# Print the image, without its tag, that config/deployments/$1.yaml runs.
function _app_image() {
  local image
  image=$(awk '$1 == "image:" { print $2; exit } $1 == "-" && $2 == "image:" { print $3; exit }' \
    "$ROOT/config/deployments/$1.yaml" 2>/dev/null) || true
  echo "${image%:*}"
}

# Print the newTag config/kustomization.yaml sets for image $1, if it sets one.
function _configured_tag() {
  awk -v image="$1" '
    $1 == "-" && $2 == "name:" { found = ($3 == image); next }
    found && $1 == "newTag:" { gsub(/["\047]/, "", $2); print $2; exit }
  ' "$ROOT/config/kustomization.yaml"
}

# True if version $1 sorts after version $2.
function _version_newer() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

# Remember that 'deploy --version' put service $1 on tag $2, so apply keeps it
# there for as long as config/kustomization.yaml is behind it.
function _record_version() {
  local app=$1 version=$2 configured
  configured=$(_configured_tag "$(_app_image "$app")")
  if _version_newer "$version" "$configured"; then
    mkdir -p "$ARCUS_CONFIGDIR/image-version"
    echo "$version" > "$ARCUS_CONFIGDIR/image-version/$app"
  else
    rm -f "$ARCUS_CONFIGDIR/image-version/$app"
  fi
}

# Add an images entry to the kustomization $1 for each service 'deploy --version'
# moved ahead of config/kustomization.yaml, so apply doesn't move it back. Once
# config/kustomization.yaml reaches that version the service follows it again.
function _keep_deployed_versions() {
  local kustomization=$1 pin app version image configured entries="" line out=""
  for pin in "$ARCUS_CONFIGDIR"/image-version/*; do
    [[ -f "$pin" ]] || continue
    app=${pin##*/}
    version=$(cat "$pin")
    image=$(_app_image "$app")
    configured=$(_configured_tag "$image")
    if [[ -z "$configured" ]]; then
      echo "${app}: no image tag in config/kustomization.yaml any more, dropping its deployed version ${version}."
      rm -f "$pin"
    elif ! _version_newer "$version" "$configured"; then
      echo "${app}: config/kustomization.yaml is at ${configured}, which has caught up with ${version}; following it again."
      rm -f "$pin"
    else
      echo "${app}: keeping ${version} from 'deploy --version' (config/kustomization.yaml has ${configured})."
      entries+="- name: ${image}"$'\n'"  newTag: ${version}"$'\n'
    fi
  done
  [[ -n "$entries" ]] || return 0

  if grep -q '^images:' "$kustomization"; then
    # Ahead of the overlay's own entries, which match the same name and may rename it
    while IFS= read -r line || [[ -n "$line" ]]; do
      out+="$line"$'\n'
      [[ "$line" == 'images:' ]] && out+="$entries"
    done < "$kustomization"
    printf '%s' "$out" > "$kustomization"
  else
    printf 'images:\n%s' "$entries" >> "$kustomization"
  fi
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

  _keep_deployed_versions "overlays/${ARCUS_OVERLAY_NAME}-local/kustomization.yaml"

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
  # Grafana health checks of the other datacenters for the blackbox-peers job,
  # their public services for blackbox-peer-public, and this cluster's own public
  # URLs for blackbox-public
  local peers="overlays/${ARCUS_OVERLAY_NAME}-local/peers.json"
  local peer_public="overlays/${ARCUS_OVERLAY_NAME}-local/peer-public.json"
  local public="overlays/${ARCUS_OVERLAY_NAME}-local/public.json"
  _peer_targets "${ARCUS_PEER_ADMIN_DOMAINS-}" > "$peers"
  _peer_public_targets "${ARCUS_PEER_ADMIN_DOMAINS-}" "$ARCUS_DOMAIN_NAME" > "$peer_public"
  _public_targets "$ARCUS_DOMAIN_NAME" "${ARCUS_ADMIN_DOMAIN-}" > "$public"
  $KUBECTL create configmap prometheus-targets --from-file=datastores.json="$targets" \
    --from-file=peers.json="$peers" --from-file=peer-public.json="$peer_public" \
    --from-file=public.json="$public" --dry-run=client -o yaml | $KUBECTL apply -f - > /dev/null

  # Alert rules with this node's thresholds, and the contact points and
  # notification policy for .config/alert-*; the overlay's generators turn
  # them into the grafana-alerting ConfigMap and grafana-notifications Secret,
  # so Grafana restarts and re-reads them when they change.
  _render_alert_rules "overlays/${ARCUS_OVERLAY_NAME}-local/alerting.yaml"
  _grafana_notifications > "overlays/${ARCUS_OVERLAY_NAME}-local/grafana-notifications.yaml"
  if [[ -n "${ARCUS_ALERT_DISCORD_WEBHOOK-}${ARCUS_ALERT_PUSHOVER_USER_KEY-}" ]]; then
    echo "Grafana alert notifications provisioned from .config/alert-*:${ARCUS_ALERT_DISCORD_WEBHOOK:+ Discord}${ARCUS_ALERT_PUSHOVER_USER_KEY:+ Pushover (critical)}."
  fi

  ensure_grafana_renderer_token
  ensure_grafana_admin_password
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

# Move deployment $1 onto image tag $2 if one is given, or restart it, and wait
# for the rollout to finish.
function _rollout_app() {
  local app=$1 version=$2 container image
  if [[ -z "$version" ]]; then
    echo "Restarting ${app}..."
    $KUBECTL rollout restart deployment/"$app"
  else
    container=$($KUBECTL get deployment/"$app" -o jsonpath='{.spec.template.spec.containers[0].name}')
    image=$($KUBECTL get deployment/"$app" -o jsonpath='{.spec.template.spec.containers[0].image}')
    if [[ "${image##*:}" == "$version" ]]; then
      echo "${app} is already on ${version}."
    else
      echo "Updating ${app} to ${version}..."
      $KUBECTL set image deployment/"$app" "${container}=${image%:*}:${version}"
    fi
  fi
  $KUBECTL rollout status deployment/"$app" --timeout=120s
  [[ -z "$version" ]] || _record_version "$app" "$version"
  echo "${app} ready."
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
  local version=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pull)
        pull=1
        shift
        ;;
      --version)
        if [[ -z "${2:-}" || "$2" == -* ]]; then
          echo "Error: --version requires an image tag (e.g. 2026.10.3)"
          return 1
        fi
        version="$2"
        shift 2
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

  if [[ -n "$version" ]]; then
    # Only services whose image tag config/kustomization.yaml sets have versions
    local versioned="" behind="" configured
    for app in $targets; do
      configured=$(_configured_tag "$(_app_image "$app")")
      if [[ -z "$configured" ]]; then
        if [[ $# -gt 0 ]]; then
          echo "Error: ${app} has no image tag in config/kustomization.yaml to change"
          return 1
        fi
        echo "Skipping ${app} (no image tag in config/kustomization.yaml)."
        continue
      fi
      versioned+="${versioned:+ }$app"
      if _version_newer "$configured" "$version"; then
        behind+="${behind:+ }$app"
      fi
    done
    targets=$versioned
    if [[ -n "$behind" ]]; then
      echo "Note: config/kustomization.yaml has a newer version than ${version} for: ${behind}."
      echo "The next apply moves these back to it."
    fi
  fi

  local mode="Rolling restart"
  [[ $pull -eq 1 ]] && mode="Pull and restart"
  [[ -n "$version" ]] && mode="Rolling update to ${version}"
  _notify_start "$mode: $targets"

  local _deploy_current_app=""
  trap 'echo ""; [[ -n "$_deploy_current_app" ]] && echo "Interrupted during: ${_deploy_current_app}"; _notify_failure "$mode interrupted"; trap - INT; kill -INT $$' INT

  # A new version is pulled before any service changes, so a tag that doesn't
  # exist stops the deploy here instead of leaving a service in ImagePullBackOff
  if [[ $pull -eq 1 || -n "$version" ]]; then
    for app in $targets; do
      _deploy_current_app="pulling $app"
      local image
      image=$($KUBECTL get deployment/"$app" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null) || true
      if [[ -z "$image" ]]; then
        echo "Warning: could not determine image for ${app}, skipping pull"
        continue
      fi
      [[ -z "$version" ]] || image="${image%:*}:${version}"
      echo "Pulling ${image}..."
      if sudo crictl pull "$image" 2>/dev/null; then
        echo "Pulled ${image}."
      elif [[ -n "$version" ]]; then
        echo "Error: could not pull ${image}. No services were changed."
        trap - INT
        _notify_failure "$mode failed: could not pull ${image}"
        return 1
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
      _deploy_current_app="rolling out $app"
      _rollout_app "$app" "$version"
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

      _rollout_app "$app" "$version" &
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
  for app in $APPS; do
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
