#!/bin/bash
set -eu

echo "Creating hub-keystore..."
mkdir -p converted
KUBE_EDITOR=cat $KUBECTL edit secret nginx-production-tls 2>/dev/null | grep tls.key | awk '{print $2}' | base64 -d > converted/orig.key
KUBE_EDITOR=cat $KUBECTL edit secret nginx-production-tls 2>/dev/null | grep tls.crt | awk '{print $2}' | base64 -d > converted/tls.crt

openssl pkcs8 -in converted/orig.key -topk8 -nocrypt -out converted/tls.key
rm converted/orig.key

set +e
$KUBECTL delete secret hub-keystore
$KUBECTL create secret generic truststore --from-file irisbylowes/truststore.jks
set -e
$KUBECTL create secret tls hub-keystore --cert converted/tls.crt --key converted/tls.key 

rm -rf converted
echo "All done. Goodbye!"
