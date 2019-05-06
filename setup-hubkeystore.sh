#!/bin/bash
set -euo pipefail

echo "Creating hub-keystore..."
mkdir -p converted
KUBE_EDITOR=cat microk8s.kubectl edit secret nginx-production-tls 2>/dev/null | grep tls.key | awk '{print $2}' | base64 -d > converted/orig.key
KUBE_EDITOR=cat microk8s.kubectl edit secret nginx-production-tls 2>/dev/null | grep tls.crt | awk '{print $2}' | base64 -d > converted/tls.crt

openssl pkcs8 -in converted/orig.key -topk8 -nocrypt -out converted/tls.key
rm converted/orig.key

microk8s.kubectl delete secret hub-keystore
microk8s.kubectl create secret tls hub-keystore --cert converted/tls.crt --key converted/tls.key 

rm -rf converted
echo "All done. Goodbye!"
