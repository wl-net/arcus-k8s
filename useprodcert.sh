#!/bin/bash

KUBECTL=${KUBECTL:-kubectl}

sed -i 's/letsencrypt-staging/letsencrypt-production/g' overlays/local-production-local/ui-service-ingress.yml
sed -i 's/nginx-staging-tls/nginx-production-tls/g' overlays/local-production-local/ui-service-ingress.yml
$KUBECTL apply -f overlays/local-production-local/ui-service-ingress.yml
