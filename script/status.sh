# shellcheck shell=bash
# Status, monitoring, and diagnostic functions

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

  local inotify_watches
  inotify_watches=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null) || true
  if [[ -n "$inotify_watches" && "$inotify_watches" -lt 524288 ]]; then
    echo ""
    echo "Warning: fs.inotify.max_user_watches is $inotify_watches (recommended: 524288)"
    echo "  Fix now:    sudo sysctl -w fs.inotify.max_user_watches=524288"
    echo "  Persist:    echo 'fs.inotify.max_user_watches=524288' | sudo tee /etc/sysctl.d/99-inotify.conf"
  fi
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

  echo ""
  echo "Hub TLS Certificate:"
  local hub_host="hub.${ARCUS_DOMAIN_NAME}"
  local hub_enddate hub_status
  hub_enddate=$(echo | openssl s_client -connect "${hub_host}:443" -servername "$hub_host" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2) || true
  if [[ -n "$hub_enddate" ]]; then
    local hub_epoch now_epoch days_left
    hub_epoch=$(date -d "$hub_enddate" +%s 2>/dev/null) || hub_epoch=0
    now_epoch=$(date +%s)
    days_left=$(( (hub_epoch - now_epoch) / 86400 ))
    if [[ $days_left -lt 7 ]]; then
      hub_status="[WARN] expires in ${days_left} days"
    else
      hub_status="[OK] expires in ${days_left} days"
    fi
    printf "  %-50s %s (%s)\n" "$hub_host" "$hub_status" "$hub_enddate"
  else
    printf "  %-50s [FAIL] could not retrieve certificate\n" "$hub_host"
    failed=1
  fi

  return $failed
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

function setup_metrics() {
  $KUBECTL apply -f config/stateful/grafana.yaml
}
