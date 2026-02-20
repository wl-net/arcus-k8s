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

