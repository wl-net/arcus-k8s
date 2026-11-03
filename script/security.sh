# shellcheck shell=bash
# Attack surface reduction

# Lockdown sets authz.disabled.risky.operations on the bridges that take client
# requests, so they refuse every operation it covers (email and phone changes;
# deleting an account, place, hub, person or login; hub factory reset) from
# everyone, account owners included. Services aren't affected, so deleting a
# place still removes its hubs.
#
# It belongs to one datacenter, so it is a live env entry on each Deployment,
# recorded in .config/lockdown, rather than a manifest line. kubectl apply only
# removes what it applied itself, so apply leaves the entry alone, and puts it
# back if a Deployment was recreated.
LOCKDOWN_APPS='client-bridge api-bridge'
LOCKDOWN_KEY='AUTHZ_DISABLED_RISKY_OPERATIONS'
LOCKDOWN_VALUE='all'

# Print the value deployment $1 has for the setting, if it has one.
function _lockdown_value() {
  $KUBECTL get deployment/"$1" \
    -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$LOCKDOWN_KEY\")].value}" 2>/dev/null
}

# Put the lockdown on any bridge missing it. apply doesn't wait for these
# rollouts, as it doesn't wait for its own.
function _lockdown_enforce() {
  local app
  for app in $LOCKDOWN_APPS; do
    $KUBECTL set env deployment/"$app" "$LOCKDOWN_KEY=$LOCKDOWN_VALUE"
  done
}

# Make the kubectl set env change $1 to one bridge at a time, waiting for each
# rollout. An unchanged value doesn't restart a bridge, so this can be run again
# to finish after a failure.
function _lockdown_roll() {
  local app
  for app in $LOCKDOWN_APPS; do
    $KUBECTL set env deployment/"$app" "$1"
    $KUBECTL rollout status deployment/"$app" --timeout=120s
  done
}

function security_lockdown() {
  _notify_start "Locking down: refusing risky client operations" "$_NOTIFY_COLOR_ORANGE"
  echo yes > "$ARCUS_CONFIGDIR/lockdown"
  _lockdown_roll "$LOCKDOWN_KEY=$LOCKDOWN_VALUE"
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
  rm -f "$ARCUS_CONFIGDIR/lockdown"
  _lockdown_roll "$LOCKDOWN_KEY-"
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
