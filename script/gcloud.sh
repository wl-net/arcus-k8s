#!/bin/bash

function enable_istio() {
	gcloud beta container clusters update arcus \
        --update-addons=Istio=ENABLED --istio-config=auth=MTLS_STRICT --zone $GCP_ZONE
}
