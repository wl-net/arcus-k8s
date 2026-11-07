# shellcheck shell=bash
# Attack surface reduction

# Lockdown sets authz.disabled.risky.operations on the bridges that take client
# requests, so they refuse every operation it covers (email and phone changes;
# deleting an account, place, hub, person or login; hub factory reset) from
# everyone, account owners included. Services aren't affected, so deleting a
# place still removes its hubs.
#
# It belongs to one datacenter, so it isn't in config/: lockdown sets it on the
# live Deployments and records it in .config/lockdown, and apply writes a patch
# into the -local overlay (_lockdown_patch) that keeps whatever value each bridge
# has, or adds the lockdown when .config/lockdown says so. A Deployment that
# apply recreates then starts locked down, and apply never lifts a lockdown;
# only unlock does.
LOCKDOWN_APPS='client-bridge api-bridge'
LOCKDOWN_KEY='AUTHZ_DISABLED_RISKY_OPERATIONS'
LOCKDOWN_VALUE='all'

# Print the value deployment $1 has for the setting, if it has one. A missing
# Deployment prints nothing; failing to ask returns non-zero.
function _lockdown_value() {
  $KUBECTL get deployment/"$1" --ignore-not-found \
    -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$LOCKDOWN_KEY\")].value}" 2>/dev/null
}

# Write lockdown.yaml into overlay directory $1 and list it in its patches, giving
# each bridge the value it has now, or the lockdown when .config/lockdown says
# so and it has none. With nothing to keep, there is no patch. If a bridge's
# setting can't be read, it returns 1 rather than leave a lockdown out.
function _lockdown_patch() {
  local overlay=$1 app value patch="" out="" line
  for app in $LOCKDOWN_APPS; do
    if ! value=$(_lockdown_value "$app"); then
      echo "Error: could not read ${app}'s lockdown setting; not applying."
      return 1
    fi
    if [[ -z "$value" && "${ARCUS_LOCKDOWN:-}" == "yes" ]]; then
      value=$LOCKDOWN_VALUE
    fi
    [[ -n "$value" ]] || continue
    patch+="apiVersion: apps/v1
kind: Deployment
metadata:
  name: $app
spec:
  template:
    spec:
      containers:
      - name: $app
        env:
        - name: $LOCKDOWN_KEY
          value: \"$value\"
---
"
  done
  rm -f "$overlay/lockdown.yaml"
  [[ -n "$patch" ]] || return 0
  printf '%s' "$patch" > "$overlay/lockdown.yaml"
  if grep -q '^patches:' "$overlay/kustomization.yaml"; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      out+="$line"$'\n'
      [[ "$line" == 'patches:' ]] && out+=$'- path: lockdown.yaml\n'
    done < "$overlay/kustomization.yaml"
    printf '%s' "$out" > "$overlay/kustomization.yaml"
  else
    printf 'patches:\n- path: lockdown.yaml\n' >> "$overlay/kustomization.yaml"
  fi
}

# Make the kubectl set env change $1 to every bridge, then wait for the
# rollouts, so a bridge that is slow to roll out doesn't hold up the other's
# change. Report each bridge that didn't take the change or finish rolling out,
# returning 1 if a bridge didn't take it and 2 if they all did but a rollout
# hadn't finished. An unchanged value doesn't restart a bridge, so this can be
# run again to finish after a failure.
function _lockdown_roll() {
  local app unchanged="" unfinished=""
  for app in $LOCKDOWN_APPS; do
    $KUBECTL set env deployment/"$app" "$1" || unchanged+=" $app"
  done
  for app in $LOCKDOWN_APPS; do
    [[ " $unchanged " == *" $app "* ]] && continue
    $KUBECTL rollout status deployment/"$app" --timeout=180s || unfinished+=" $app"
  done
  [[ -z "$unchanged$unfinished" ]] && return 0
  if [[ -n "$unchanged" ]]; then
    echo "Error: could not change${unchanged}; it still runs with its old setting."
  fi
  if [[ -n "$unfinished" ]]; then
    echo "Error:${unfinished} took the change, but the rollout hadn't finished after 3 minutes;"
    echo "pods still on the old setting keep serving until it does. Check with"
    echo "'kubectl rollout status deployment/<name>'."
  fi
  [[ -n "$unchanged" ]] && return 1
  return 2
}

# Lockdown records itself before touching the bridges, and unlock removes the
# record only once both Deployments have taken the change (their rollouts may
# still be going), so an interrupted run leaves the datacenter recorded as
# locked and the next apply finishes it.
function security_lockdown() {
  _notify_start "Locking down: refusing risky client operations" "$_NOTIFY_COLOR_ORANGE"
  echo yes > "$ARCUS_CONFIGDIR/lockdown"
  if ! _lockdown_roll "$LOCKDOWN_KEY=$LOCKDOWN_VALUE"; then
    echo "The lockdown is incomplete. Run './arcuscmd.sh security lockdown' again to finish it."
    exit 1
  fi
  cat <<EOF
Lockdown set on client-bridge and api-bridge. A build with this feature refuses
email and phone changes, hub factory resets, and deleting accounts, places, hubs,
people and logins, from every client, account owners included. An older build
ignores the setting. Services aren't affected.
It covers this datacenter only; run it in the others too.
EOF
}

function security_unlock() {
  _notify_start "Lifting lockdown" "$_NOTIFY_COLOR_ORANGE"
  local rc=0
  _lockdown_roll "$LOCKDOWN_KEY-" || rc=$?
  [[ $rc -eq 1 ]] || rm -f "$ARCUS_CONFIGDIR/lockdown"
  if [[ $rc -ne 0 ]]; then
    echo "The lockdown was not fully lifted. Run './arcuscmd.sh security unlock' again to finish."
    exit 1
  fi
  echo "Lockdown lifted in this datacenter: clients can use risky operations again."
}

function security_status() {
  local app value expected="" state=off drift=0
  if [[ "${ARCUS_LOCKDOWN:-}" == "yes" ]]; then
    expected=$LOCKDOWN_VALUE
    state=on
  fi
  echo "Lockdown: $state"
  for app in $LOCKDOWN_APPS; do
    value=$(_lockdown_value "$app") || value=""
    printf "  %-16s refusing %s\n" "$app" "${value:-nothing}"
    [[ "$value" == "$expected" ]] || drift=1
  done
  if [[ $drift -eq 1 ]]; then
    echo "  Warning: the bridges don't match .config/lockdown. Run './arcuscmd.sh security lockdown' or 'unlock'."
  fi
}

function security() {
  case "${1:-status}" in
  lockdown) security_lockdown ;;
  unlock) security_unlock ;;
  status) security_status ;;
  *)
    echo "Usage: arcuscmd security [status|lockdown|unlock]"
    exit 1
    ;;
  esac
}
