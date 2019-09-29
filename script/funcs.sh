function updatehubkeystore {
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
}

function useprodcert {
	sed -i 's/letsencrypt-staging/letsencrypt-production/g' overlays/local-production-local/ui-service-ingress.yml
	sed -i 's/nginx-staging-tls/nginx-production-tls/g' overlays/local-production-local/ui-service-ingress.yml
	$KUBECTL apply -f overlays/local-production-local/ui-service-ingress.yml
}

function runmodelmanager {
	set +e
	$KUBECTL delete pod -l app=modelmanager-platform
        $KUBECTL delete job modelmanager-platform

	$KUBECTL delete pod -l app=modelmanager-history
        $KUBECTL delete job modelmanager-history

        $KUBECTL delete pod -l app=modelmanager-video
        $KUBECTL delete job modelmanager-video

	set -e
        $KUBECTL apply -f config/jobs/
}

APPS='alarm-service client-bridge driver-services subsystem-service history-service hub-bridge ipcd-bridge ivr-callback-server metrics-server notification-services platform-services rule-service scheduler-service ui-server'
function deployfast {
	$KUBECTL delete pod -l app=cassandra
	$KUBECTL delete pod -l app=zookeeper
	$KUBECTL delete pod -l app=kafka
	for app in $APPS; do
            $KUBECTL delete pod -l app=$app
	    sleep 5
	done
}
