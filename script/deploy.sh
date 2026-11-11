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

# Write config/extrafiles/loki.yaml to $1 with PLACEHOLDER_LOKI_RETENTION filled
# from .config/loki-retention-days (default 7), how many days Loki keeps logs.
# Grafana's alert state history keeps its own 30 days (retention_stream).
function _render_loki_config() {
  local days="${ARCUS_LOKI_RETENTION_DAYS:-7}"
  if ! [[ "$days" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: .config/loki-retention-days must be a whole number of days, not '${days}'."
    return 1
  fi
  sed "s/PLACEHOLDER_LOKI_RETENTION/$((days * 24))h/" "$ROOT/config/extrafiles/loki.yaml" > "$1"
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

# The modelmanager Jobs in config/jobs/ make the Cassandra schema changes a
# release needs. apply and 'deploy --version' run them at the release's tag
# before any service changes, and stop if one fails, so a service never starts
# on a release whose schema changes haven't been made. They carry the label
# arcus.io/role=schema-migration, which keeps them out of apply's kubectl
# apply -k: a Job's pod template can't be changed, only replaced.

# The modelmanager image, without its tag, as config/jobs/ names it.
function _schema_image() {
  local image
  image=$(awk '$1 == "image:" { print $2; exit }' "$ROOT/config/jobs/modelmanager-platform.yaml" 2>/dev/null) || true
  [[ "${image##*/}" == *:* ]] && image=${image%:*}
  echo "$image"
}

# The tag the schema jobs run at: modelmanager's in config/kustomization.yaml,
# or the newest version 'deploy --version' has moved a service ahead to.
function _schema_tag() {
  local tag pin version
  tag=$(_configured_tag "$(_schema_image)")
  for pin in "$ARCUS_CONFIGDIR"/image-version/*; do
    [[ -f "$pin" ]] || continue
    version=$(cat "$pin")
    if [[ -z "$tag" ]] || _version_newer "$version" "$tag"; then
      tag=$version
    fi
  done
  echo "$tag"
}

# Write what the -local overlay renders for the schema jobs into directory $1:
# each Job as jobs/<name>.yaml, and the ConfigMaps they read as configmaps.yaml.
function _render_schema_jobs() {
  mkdir -p "$1/jobs"
  $KUBECTL kustomize "overlays/${ARCUS_OVERLAY_NAME}-local" | awk -v out="$1" '
    function flush(  file) {
      if (kind == "Job" && role == "schema-migration") file = out "/jobs/" name ".yaml"
      else if (kind == "ConfigMap" && (name == "cluster-config" || name == "arcus-config")) file = out "/configmaps.yaml"
      if (file != "") { printf "---\n%s", doc >> file; close(file) }
      doc = ""; kind = ""; name = ""; role = ""; meta = 0
    }
    $0 == "---" { flush(); next }
    {
      doc = doc $0 "\n"
      if ($1 == "kind:" && !/^ /) kind = $2
      if ($0 == "metadata:") { meta = 1; next }
      if (meta && !/^  /) meta = 0
      if (meta && /^  name: /) name = $2
      if (meta && /^    arcus\.io\/role: /) role = $2
    }
    END { flush() }
  '
}

# A hash of schema job file $1 leaving out its image tag, so a job is run again
# when anything but the version changes.
function _schema_spec_hash() {
  sed -E 's#^( +image: [^ ]+):[^:/ ]+$#\1#' "$1" | sha256sum | cut -c1-16
}

# Wait for the schema jobs named in $@ to finish. Prints how each one ended,
# with the reason and the end of the log for a failure; returns non-zero if
# any failed. A job whose pod can't start (an image that can't be pulled, a
# missing ConfigMap key) is deleted and counts as failed straight away.
function _wait_schema_jobs() {
  local start=$SECONDS next_note=30 failed=0 name state reason stuck log changes
  local pending=("$@") still
  while [[ ${#pending[@]} -gt 0 ]]; do
    sleep 3
    still=()
    for name in "${pending[@]}"; do
      if ! state=$($KUBECTL get job "$name" --ignore-not-found \
          -o jsonpath='{.metadata.name}{" "}{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}' 2>/dev/null); then
        still+=("$name")   # the API didn't answer; ask again
        continue
      fi
      case "$state " in
        " ")
          echo "${name}: the Job was deleted before it finished."
          failed=1
          ;;
        *" Complete "*)
          # modelmanager lists what it's about to do: "N)  <source>::<id> -
          # <description>" per changeset, then "Import localization strings",
          # which it does every run
          log=$($KUBECTL logs "job/${name}" --tail=-1 2>/dev/null) || true
          changes=$(grep -E '^[0-9]+\)  ' <<< "$log" | grep -vE '^[0-9]+\)  Import localization strings$') || true
          if [[ -n "$changes" ]]; then
            echo "${name}: done in $((SECONDS - start))s. Schema changes made:"
            sed -E 's/^[0-9]+\)  /    /' <<< "$changes"
          elif grep -q '^The following upgrade changes will be executed:' <<< "$log"; then
            echo "${name}: done in $((SECONDS - start))s, no schema changes."
          else
            echo "${name}: done in $((SECONDS - start))s."
          fi
          ;;
        *" Failed "*)
          reason=$($KUBECTL get job "$name" -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}' 2>/dev/null) || true
          echo "${name}: failed (${reason:-no reason given}). The end of its log:"
          $KUBECTL logs "job/${name}" --tail=30 2>&1 | sed 's/^/    /' || true
          failed=1
          ;;
        *)
          stuck=$($KUBECTL get pods -l "batch.kubernetes.io/job-name=${name}" \
              -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{": "}{.status.containerStatuses[0].state.waiting.message}{"\n"}{end}' 2>/dev/null \
            | grep -E '^(ErrImagePull|ImagePullBackOff|InvalidImageName|CreateContainerConfigError|CreateContainerError):' | head -n 1) || true
          if [[ -n "$stuck" ]]; then
            echo "${name}: its pod can't start: ${stuck}"
            echo "${name}: deleting the Job, so it doesn't keep retrying."
            $KUBECTL delete job "$name" --ignore-not-found > /dev/null 2>&1 || true
            failed=1
          elif [[ $((SECONDS - start)) -gt 1900 ]]; then
            # Past the Jobs' activeDeadlineSeconds, which should have failed it
            echo "${name}: still not finished after $(((SECONDS - start) / 60)) minutes; giving up waiting."
            failed=1
          else
            still+=("$name")
          fi
          ;;
      esac
    done
    pending=("${still[@]}")
    if [[ ${#pending[@]} -gt 0 && $((SECONDS - start)) -ge $next_note ]]; then
      echo "Still running after $((SECONDS - start))s: ${pending[*]}"
      next_note=$((next_note + 30))
    fi
  done
  return "$failed"
}

# Run the schema jobs at image tag $2 (the rendered tag if empty) and wait for
# them. Returns non-zero, before anything else changes, if one fails.
#   $1 force: always run them.
#      auto:  skip a job whose last run succeeded with the same spec at this
#             tag or a newer one. A newer schema contains an older one, so
#             moving a service back doesn't run an older modelmanager over it.
#   $3 required: pull the image first and fail if it can't be pulled, so a tag
#                that doesn't exist stops here ('deploy --version').
#      try:      pull it first, keeping the cached copy if that fails ('deploy --pull').
function _run_schema_jobs() {
  local dir rc=0
  dir=$(mktemp -d)
  _run_schema_jobs_in "$dir" "$@" || rc=$?
  rm -rf "$dir"
  return "$rc"
}

# A schema Job's spec hash, image, succeeded and active counts, and true
# conditions, separated by |; empty if it doesn't exist
function _schema_job_live() {
  $KUBECTL get job "$1" --ignore-not-found \
    -o jsonpath='{.metadata.annotations.arcus\.io/spec-hash}{"|"}{.spec.template.spec.containers[0].image}{"|"}{.status.succeeded}{"|"}{.status.active}{"|"}{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}'
}

function _run_schema_jobs_in() {
  local dir=$1 mode=$2 tag=$3 pull=${4:-}
  local f name image want live live_hash live_image live_ok live_active live_conditions
  local to_run=() pulled=""

  if ! _render_schema_jobs "$dir"; then
    echo "Error: could not render the schema jobs from overlays/${ARCUS_OVERLAY_NAME}-local."
    return 1
  fi
  if ! compgen -G "$dir/jobs/*.yaml" > /dev/null; then
    echo "Error: overlays/${ARCUS_OVERLAY_NAME}-local renders no Jobs labelled arcus.io/role=schema-migration."
    return 1
  fi

  for f in "$dir"/jobs/*.yaml; do
    name=${f##*/}
    name=${name%.yaml}
    [[ -z "$tag" ]] || sed -i -E "s#^( +image: [^ ]+):[^:/ ]+\$#\\1:${tag}#" "$f"
    image=$(awk '$1 == "image:" { print $2; exit }' "$f")
    if [[ "${image##*/}" != *:* ]]; then
      echo "Error: ${name} has no image tag; config/kustomization.yaml should set one for ${image}."
      return 1
    fi
    want=${image##*:}

    if [[ -n "$pull" && " $pulled " != *" $image "* ]]; then
      echo "Pulling ${image}..."
      if sudo crictl pull "$image" > /dev/null 2>&1; then
        pulled+=" $image"
      elif [[ "$pull" == required ]]; then
        echo "Error: could not pull ${image}."
        return 1
      else
        echo "Failed to pull ${image}, continuing with the cached image."
        pulled+=" $image"
      fi
    fi

    live=$(_schema_job_live "$name") || return 1
    IFS='|' read -r live_hash live_image live_ok live_active live_conditions <<< "$live"

    # The controller stops updating a Job once it has finished, so a stale
    # active count on a finished one doesn't mean a run (Jobs from 2020 have them)
    if [[ "${live_active:-0}" -gt 0 && " $live_conditions " != *" Complete "* \
          && " $live_conditions " != *" Failed "* ]]; then
      # An interrupted apply, or ./arcuscmd.sh modelmanager run elsewhere:
      # don't cut a migration off halfway
      echo "${name}: a run of ${live_image##*:} is already in progress; waiting for it first."
      _wait_schema_jobs "$name" || true
      live=$(_schema_job_live "$name") || return 1
      IFS='|' read -r live_hash live_image live_ok live_active live_conditions <<< "$live"
    fi

    if [[ "$mode" != force && "$live_hash" == "$(_schema_spec_hash "$f")" \
          && "${live_image%:*}" == "${image%:*}" && "${live_ok:-0}" -ge 1 ]] \
        && ! _version_newer "$want" "${live_image##*:}"; then
      if [[ "${live_image##*:}" == "$want" ]]; then
        echo "${name}: already ran at ${want}."
      else
        echo "${name}: already ran at ${live_image##*:}, newer than ${want}; leaving the schema as it is."
      fi
      continue
    fi
    to_run+=("$name")
  done

  [[ ${#to_run[@]} -gt 0 ]] || return 0

  # The jobs read their hosts and keyspace from these; on a new cluster this
  # creates them
  if [[ -f "$dir/configmaps.yaml" ]]; then
    $KUBECTL apply -f "$dir/configmaps.yaml" > /dev/null || return 1
  fi

  for name in "${to_run[@]}"; do
    f="$dir/jobs/${name}.yaml"
    image=$(awk '$1 == "image:" { print $2; exit }' "$f")
    $KUBECTL delete job "$name" --ignore-not-found --cascade=foreground --timeout=120s > /dev/null || return 1
    $KUBECTL label --local -f "$f" -o yaml --overwrite "app.kubernetes.io/version=${image##*:}" \
      | $KUBECTL annotate --local -f - -o yaml --overwrite "arcus.io/spec-hash=$(_schema_spec_hash "$f")" \
      | $KUBECTL create -f - > /dev/null || return 1
    echo "${name}: running modelmanager ${image##*:}..."
  done
  _wait_schema_jobs "${to_run[@]}"
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
  # Keep each bridge's lockdown setting, or add it when .config/lockdown says so.
  # This reads the cluster, so it runs before apply changes anything there.
  _lockdown_patch "overlays/${ARCUS_OVERLAY_NAME}-local"

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

  # Alert rules with this node's thresholds, Loki's config with its retention,
  # and the contact points and notification policy for .config/alert-*; the
  # overlay's generators turn them into the grafana-alerting and loki-config
  # ConfigMaps and the grafana-notifications Secret, so Grafana and Loki
  # restart and re-read them when they change.
  _render_alert_rules "overlays/${ARCUS_OVERLAY_NAME}-local/alerting.yaml"
  _render_loki_config "overlays/${ARCUS_OVERLAY_NAME}-local/loki.yaml"
  _grafana_notifications > "overlays/${ARCUS_OVERLAY_NAME}-local/grafana-notifications.yaml"
  if [[ -n "${ARCUS_ALERT_DISCORD_WEBHOOK-}${ARCUS_ALERT_PUSHOVER_USER_KEY-}" ]]; then
    echo "Grafana alert notifications provisioned from .config/alert-*:${ARCUS_ALERT_DISCORD_WEBHOOK:+ Discord}${ARCUS_ALERT_PUSHOVER_USER_KEY:+ Pushover (critical)}."
  fi

  ensure_grafana_renderer_token
  ensure_grafana_admin_password
  $KUBECTL create secret generic shared --from-file secret/ --dry-run=client -o yaml | $KUBECTL apply -f - > /dev/null

  # The schema changes this release needs, before any Deployment changes
  if ! _run_schema_jobs auto "$(_schema_tag)"; then
    echo ""
    echo "Error: a schema job failed, so no Deployment was changed. Fix the cause and run"
    echo "apply again; ./arcuscmd.sh modelmanager runs the schema jobs on their own."
    exit 1
  fi

  # Show what would change before applying, leaving out the schema jobs, which
  # were just run. kubectl diff exits 0 = no diff, 1 = has diff, >1 = error.
  local diff_exit=0
  $KUBECTL diff -k "overlays/${ARCUS_OVERLAY_NAME}-local" -l 'arcus.io/role!=schema-migration' 2>/dev/null || diff_exit=$?
  if [[ $diff_exit -eq 0 ]]; then
    echo "No changes to apply."
  else
    $KUBECTL apply -k "overlays/${ARCUS_OVERLAY_NAME}-local" -l 'arcus.io/role!=schema-migration'
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

  # The schema changes the new version needs, before any service moves to it.
  # A rebuilt tag ('--pull') can bring new ones too, so then they always run.
  if [[ $pull -eq 1 || -n "$version" ]]; then
    _deploy_current_app="schema jobs"
    local schema_mode=auto schema_pull=required
    [[ $pull -eq 1 ]] && schema_mode=force
    [[ -z "$version" ]] && schema_pull=try
    if ! _run_schema_jobs "$schema_mode" "${version:-$(_schema_tag)}" "$schema_pull"; then
      echo "Error: a schema job failed, so no services were changed."
      trap - INT
      _notify_failure "$mode failed: a schema job failed"
      return 1
    fi
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

# Run the schema jobs now, whether or not they have run at this version, and
# wait for them. apply and 'deploy --version' run them on their own.
function runmodelmanager() {
  if [[ ! -d "overlays/${ARCUS_OVERLAY_NAME}-local" ]]; then
    echo "Error: overlay 'overlays/${ARCUS_OVERLAY_NAME}-local' not found."
    echo "Run './arcuscmd.sh apply', which runs the schema jobs itself."
    return 1
  fi
  # modelmanager-video is gone (modelmanager no longer ships video-resources);
  # deleting it still clears the Job a cluster has left from earlier runs.
  $KUBECTL delete job modelmanager-video --ignore-not-found > /dev/null
  _run_schema_jobs force "$(_schema_tag)"
}
