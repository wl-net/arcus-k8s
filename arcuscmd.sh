#!/bin/bash
set -euo pipefail

METALLB_VERSION='v0.8.1'
NGINX_VERSION='0.26.0'
CERT_MANAGER_VERSION='v0.10.1'

SCRIPT_PATH="$0"
SCRIPT_DIR=$(dirname ${SCRIPT_PATH})
. "${SCRIPT_DIR}/script/common.sh"
. "${SCRIPT_DIR}/script/funcs.sh"

# setup

set +e
ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
RESULT=$?
if [ $RESULT -ne 0 ]; then
  echo "Couldn't get root of git repository. You must checkout arcus-k8 as a git repository, not as an extracted zip."
  exit $RESULT
fi
set -e

ARCUS_CONFIGDIR="${ROOT}/.config"
mkdir -p $ARCUS_CONFIGDIR

KUBECTL=${KUBECTL:-kubectl}

DEPLOYMENT_TYPE=cloud

if [ -x "$(command -v microk8s.kubectl)" ]; then
  KUBECTL=microk8s.kubectl
  DEPLOYMENT_TYPE=local
fi

function print_available {
  cat << ENDOFDOC
arcuscmd: manage your arcus deployment

Basic Commands:
  install    - install microk8s for local (on-prem) deployment
  configure  - configure arcus by answering a few questions
  apply      - apply the existing configured configuration
  deploy     - deploy arcus (rolling the entire fleet, 1 service at a time)
  update     - update your local copy with the latest changes
ENDOFDOC

}

cmd=${1:-help}

case "$cmd" in
	setup)
            prompt answer "Setup Arcus on this machine, or in the cloud: [local/cloud]:"
	    if [[ $answer != 'cloud' && $answer != 'local' ]]; then
              echo "Invalid option $answer, must pick 'local' or 'cloud'"
              exit 1
	    fi

	    if [[ $answer == 'local' ]]; then
              DEPLOYMENT_TYPE=local
	      setupmicrok8s
	      install
	      configure
	      apply
	      provision
	      info
	    fi
	;;
        apply)
             apply
        ;;
	provision)
	     provision
	;;
        installmicrok8s)
             setupmicrok8s
        ;;
	install)
             install
        ;;
        configure)
	     configure
        ;;
        deploy)
             deployfast
        ;;
        updatehubkeystore)
	     updatehubkeystore
	;;
        modelmanager)
             runmodelmanager
        ;;
	useprodcert)
	     useprodcert
	;;
        info)
	     info
        ;;
        update)
             update
        ;;
        logs)
             logs $*
        ;;
        help)
             print_available
        ;;
        *)
            echo "unsupported command: $cmd"
	    print_available
esac
