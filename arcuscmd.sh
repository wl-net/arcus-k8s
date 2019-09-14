#!/bin/bash
set -euo pipefail

. script/funcs.sh

KUBECTL=${KUBECTL:-kubectl}

cmd=${1:-help}

case "$cmd" in
	setup)
            echo "setup local"
	;;
        apply)
             ./kustomize build overlays/local-production-local/ | $KUBECTL apply -f -
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
        *)
            echo "unsupported command"
esac

