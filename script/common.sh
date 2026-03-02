#!/bin/bash

function retry {
  local retries=$1
  shift

  local count=0
  until "$@"; do
    exit=$?
    wait=$((2 ** count))
    count=$((count + 1))
    if [ "$count" -lt "$retries" ]; then
      echo "Retry $count/$retries exited $exit, retrying in $wait seconds..."
      sleep $wait
    else
      echo "Retry $count/$retries exited $exit, no more retries left."
      return $exit
    fi
  done
  return 0
}

function prompt() {
  local __resultvar=$1
  echo -n "${2} "
  local myresult=''
  read -r myresult
  printf -v "$__resultvar" '%s' "$myresult"
}

# shellcheck disable=SC2034 # used in deploy.sh, status.sh
APPS='alarm-service api-bridge client-bridge driver-services subsystem-service history-service hub-bridge ivr-callback-server notification-services platform-services rule-service scheduler-service ui-server'

_load_config() {
  local var=$1 file=$2
  if [[ -f "$ARCUS_CONFIGDIR/$file" ]]; then
    printf -v "$var" '%s' "$(cat "$ARCUS_CONFIGDIR/$file")"
  fi
}

function load() {
  # shellcheck disable=SC2034 # used in deploy.sh, config.sh, status.sh
  ARCUS_OVERLAY_NAME="local-production"
  if [[ -d "$ARCUS_CONFIGDIR" ]]; then
    _load_config ARCUS_ADMIN_EMAIL     admin.email
    _load_config ARCUS_DOMAIN_NAME     domain.name
    _load_config ARCUS_SUBNET          subnet
    _load_config ARCUS_CERT_TYPE       cert-issuer
    _load_config ARCUS_OVERLAY_NAME    overlay-name
    _load_config ARCUS_CASSANDRA_HOST  cassandra-host
    _load_config ARCUS_ZOOKEEPER_HOST  zookeeper-host
    _load_config ARCUS_KAFKA_HOST      kafka-host
    _load_config ARCUS_PROXY_REAL_IP   proxy-real-ip
    _load_config ARCUS_ADMIN_DOMAIN    admin-domain
    _load_config ARCUS_METALLB         metallb
    _load_config ARCUS_CERT_SOLVER     cert-solver
    _load_config ARCUS_ROUTE53_ZONE_ID route53-hosted-zone-id
    _load_config ARCUS_ROUTE53_REGION  route53-region
    _load_config ARCUS_ROUTE53_SET_ID  route53-set-identifier
    _load_config ARCUS_DISCORD_WEBHOOK discord-webhook

    if [[ -z "${ARCUS_METALLB:-}" && -f "$ARCUS_CONFIGDIR/subnet" ]]; then
      # Upgrade path: existing installs that have a subnet configured were
      # using MetalLB before the opt-in flag existed.  Preserve that behavior.
      ARCUS_METALLB="yes"
    fi
  fi
}

function require_config() {
  load
  if [[ -z "${ARCUS_DOMAIN_NAME:-}" || "${ARCUS_DOMAIN_NAME:-}" == "example.com" ]]; then
    echo "Error: Arcus is not configured. Run './arcuscmd.sh configure' first."
    exit 1
  fi
}
