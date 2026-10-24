# shellcheck shell=bash
# Status, monitoring, and diagnostic functions

function arcus_status() {
  load

  # Node health
  echo "Node:"
  local warnings=0
  local mem_avail mem_total mem_pct
  mem_avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
  mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  mem_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
  local disk_pct
  disk_pct=$(df --output=pcent / | tail -1 | tr -d ' %')
  local load_avg
  load_avg=$(cut -d' ' -f1-3 /proc/loadavg)
  printf "  %-16s memory %s%%  disk %s%%  load %s\n" "$(hostname)" "${mem_pct}" "${disk_pct}" "$load_avg"
  if [[ -f /var/run/reboot-required ]]; then
    echo "  Warning: reboot required"
    warnings=1
  fi
  local inotify_watches
  inotify_watches=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null) || true
  if [[ -n "$inotify_watches" && "$inotify_watches" -lt 524288 ]]; then
    echo "  Warning: fs.inotify.max_user_watches is $inotify_watches (recommended: 524288)"
    warnings=1
  fi
  if [[ $warnings -eq 0 ]]; then
    echo "  No warnings"
  fi

  # Drain state
  if [[ -f .cache/route53-saved-weight ]]; then
    local drain_duration="unknown"
    if [[ -f .cache/route53-drain-time ]]; then
      local drain_time now elapsed
      drain_time=$(cat .cache/route53-drain-time)
      now=$(date +%s)
      elapsed=$(( now - drain_time ))
      drain_duration=$(_format_drain_duration "$elapsed")
    fi
    echo ""
    echo "Traffic:"
    echo "  WARNING: cluster is DRAINED (Route 53 weight 0) — drained ${drain_duration} ago"
    echo "  Run './arcuscmd.sh resume' to restore traffic."
  fi

  # Application services — show pods, not just deployments
  echo ""
  echo "Application Services:"
  set +e
  # shellcheck disable=SC2086
  $KUBECTL get deployments $APPS --ignore-not-found
  set -e

  echo ""
  echo "Arcus Builds:"
  _arcus_builds

  local pin header="Ahead of config/kustomization.yaml (deploy --version):"
  for pin in "$ARCUS_CONFIGDIR"/image-version/*; do
    [[ -f "$pin" ]] || continue
    if [[ -n "$header" ]]; then
      printf '\n%s\n' "$header"
      header=""
    fi
    printf "  %-24s %s (configured: %s)\n" "${pin##*/}" "$(cat "$pin")" \
      "$(_configured_tag "$(_app_image "${pin##*/}")")"
  done

  # Show pods that are not fully healthy
  local unhealthy
  unhealthy=$($KUBECTL get pods -l '!job-name' -o wide --no-headers 2>/dev/null | awk '
    # Not Running (CrashLoopBackOff, Pending, Error, Init:*, etc.)
    $3 != "Running" { print; next }
    # Running but not all containers ready (e.g. 0/1)
    {
      split($2, a, "/")
      if (a[1] != a[2]) print
    }
  ')
  if [[ -n "$unhealthy" ]]; then
    echo ""
    echo "Unhealthy Pods:"
    echo "$unhealthy"
  fi

  # Show pods with high restart counts
  local restarting
  restarting=$($KUBECTL get pods -l '!job-name' --no-headers 2>/dev/null | awk '$4+0 >= 3 { print }')
  if [[ -n "$restarting" ]]; then
    echo ""
    echo "Pods with restarts:"
    echo "$restarting"
  fi

  local external_hosts=()
  [[ -n "${ARCUS_CASSANDRA_HOST-}" ]] && external_hosts+=("cassandra:${ARCUS_CASSANDRA_HOST}")
  [[ -n "${ARCUS_KAFKA_HOST-}" ]]     && external_hosts+=("kafka:${ARCUS_KAFKA_HOST}")
  [[ -n "${ARCUS_ZOOKEEPER_HOST-}" ]] && external_hosts+=("zookeeper:${ARCUS_ZOOKEEPER_HOST%%/*}")  # drop any /chroot

  if [[ ${#external_hosts[@]} -gt 0 ]]; then
    echo ""
    echo "External Services:"
    for entry in "${external_hosts[@]}"; do
      local name="${entry%%:*}"
      local hosts_str="${entry#*:}"
      IFS=',' read -ra hosts <<< "$hosts_str"
      for host in "${hosts[@]}"; do
        host="${host// /}"  # trim spaces
        host="${host%%:*}"  # drop the port
        [[ -n "$host" ]] || continue
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

  # Alert rules made by hand in Grafana, which config/grafana/alerting.yaml doesn't
  # manage (needs the API token 'silence' creates)
  if $KUBECTL get secret "$GRAFANA_SECRET_NAME" &>/dev/null; then
    local unmanaged
    unmanaged=$({ _grafana_api GET /api/v1/provisioning/alert-rules; echo; _grafana_api GET /api/folders; } 2>/dev/null \
      | python3 -c '
import sys, json
rules, folders = sys.stdin.read().split("\n", 1)
names = {f["uid"]: f["title"] for f in json.loads(folders)}
for r in json.loads(rules):
    if r.get("provenance") != "file":
        print("  %s  (folder: %s)" % (r["title"], names.get(r["folderUID"], r["folderUID"])))' 2>/dev/null) || true
    if [[ -n "$unmanaged" ]]; then
      echo ""
      echo "Grafana alert rules not managed by config/grafana/alerting.yaml:"
      echo "$unmanaged"
      echo "  Move them into alerting.yaml or delete them in Grafana (Alerting > Alert rules)."
    fi
  fi

  echo ""
  infra_versions
}

# Print the build each service runs, grouped so a mixed rollout stands out.
# The build (version, commit and build time) comes from _app_build; the nginx
# images carry none, so they show their image tag. The images of one release
# are built seconds apart, so services group by version and commit, under the
# build time of the first one listed.
function _arcus_builds() {
  local -A apps_by_build=() built_at=()
  local -a builds=()
  local app image build built
  while read -r app image; do
    IFS='|' read -r build built < <(_app_build "$app") || true
    [[ -n "$build" ]] || build="image tag ${image##*:} (no build info)"
    if [[ -z "${apps_by_build[$build]+x}" ]]; then
      builds+=("$build")
      built_at[$build]=$built
    fi
    apps_by_build[$build]+="${apps_by_build[$build]:+, }$app"
  done < <(
    # shellcheck disable=SC2086
    $KUBECTL get deployments $APPS static-server --ignore-not-found \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null
  )
  if [[ ${#builds[@]} -eq 0 ]]; then
    echo "  No Arcus deployments found"
    return
  fi
  for build in "${builds[@]}"; do
    echo "  $build${built_at[$build]:+, built ${built_at[$build]}}"
    fold -s -w 92 <<< "${apps_by_build[$build]}" | sed 's/ *$//; s/^/    /'
  done
}

# Print "v<version> (<commit>)|<build time>" for a service, or nothing. It reads
# META-INF/application.properties from the service's jar in the running pod:
# the jar's entries are stored uncompressed, so grep finds the lines there. A
# pod that can't be exec'd into (crash looping, say) falls back to the banner
# the service logs at startup, which the kubelet's log rotation eventually drops.
function _app_build() {
  local app=$1 build
  build=$($KUBECTL exec "deploy/$app" -- sh -c \
    "grep -a -h -m3 -E '^(application\.version|build\.timestamp|build\.commit)=' /$app-[0-9]*/lib/$app-[0-9]*.jar" 2>/dev/null \
    | awk -F= '{ v[$1] = $2 }
      END { if (v["application.version"] != "" && v["build.commit"] != "")
              printf "v%s (%s)|%s\n", v["application.version"], v["build.commit"], v["build.timestamp"] }') || true
  if [[ -n "$build" ]]; then
    echo "$build"
    return
  fi
  $KUBECTL logs "deploy/$app" --limit-bytes=4194304 2>/dev/null | grep -m1 -F '[built: ' \
    | sed -E 's/^[[:space:]]*[^ ]+ v([^ ]+) \(([^)]*)\) \[built: ([^]]*)\].*/v\1 (\2)|\3/' || true
}

function infra_versions() {
  echo "Infrastructure:"
  set +e
  _infra_version_check "metallb" \
    "$($KUBECTL get deployment -n metallb-system controller -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP 'v[\d.]+')" \
    "$METALLB_VERSION"
  _infra_version_check "traefik" \
    "$($KUBECTL get deployment -n kube-system traefik -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP '[\d.]+$')" \
    "$TRAEFIK_VERSION"
  _infra_version_check "cert-manager" \
    "$($KUBECTL get deployment -n cert-manager cert-manager -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP 'v[\d.]+')" \
    "$CERT_MANAGER_VERSION"
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
  IPADDRESS=$($KUBECTL get service -n kube-system traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  HUB_IPADDRESS=$($KUBECTL get service hub-bridge-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

  echo "DNS -> IP/Port Mappings: "
  echo "If these IP addresses are private, you are responsible for setting up port forwarding"
  echo ""
  echo "${ARCUS_DOMAIN_NAME}:80           -> $IPADDRESS:80"
  echo "${ARCUS_DOMAIN_NAME}:443          -> $IPADDRESS:443"
  echo "client.${ARCUS_DOMAIN_NAME}:443   -> $IPADDRESS:443"
  echo "static.${ARCUS_DOMAIN_NAME}:443   -> $IPADDRESS:443"
  echo "ipcd.${ARCUS_DOMAIN_NAME}:443     -> $IPADDRESS:443"
  echo "admin.${ARCUS_DOMAIN_NAME}:443    -> $IPADDRESS:443"
  echo "hub.${ARCUS_DOMAIN_NAME}:8082     -> $HUB_IPADDRESS:8082"
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
    # Under pipefail a missing dig, or getent finding nothing, would exit the script
    resolved=$(dig +short "$host" 2>/dev/null | tail -1) || true
    if [[ -z "$resolved" ]]; then
      resolved=$(getent hosts "$host" 2>/dev/null | awk '{print $1}') || true
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

function httplogs() {
  $KUBECTL logs --tail=1000 -n kube-system -l app.kubernetes.io/name=traefik "$@"
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
