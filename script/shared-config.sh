#!/bin/bash

ARCUS_ADMIN_EMAIL=${ARCUS_ADMIN_EMAIL:-me@example.com}

if [ "$ARCUS_ADMIN_EMAIL" = "me@example.com" ]; then
  prompt ARCUS_ADMIN_EMAIL "Please enter your admin email address (or set ARCUS_ADMIN_EMAIL): "
fi

cp -r overlays/local-production/* overlays/local-production-local
sed -i "s/me@example.com/$ARCUS_ADMIN_EMAIL/" overlays/local-production-local/cert-provider.yaml

ARCUS_DOMAIN_NAME=${ARCUS_DOMAIN_NAME:-example.com}

if [ "$ARCUS_DOMAIN_NAME" = "example.com" ]; then
  prompt ARCUS_DOMAIN_NAME "Please enter your domain name (or set ARCUS_DOMAIN_NAME): "
fi
cp config/shared-config/config.yml overlays/local-production-local/shared-config.yaml
sed -i "s/arcussmarthome.com/$ARCUS_DOMAIN_NAME/" overlays/local-production-local/shared-config.yaml

cp config/service/ui-service-ingress.yml overlays/local-production-local/ui-service-ingress.yml
sed -i "s/arcussmarthome.com/$ARCUS_DOMAIN_NAME/" overlays/local-production-local/ui-service-ingress.yml
