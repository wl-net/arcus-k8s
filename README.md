# arcus-gcp
Google Cloud Configuration for GCP

# Prerequisites

You need to have a Google Cloud account, and have configured gcloud and docker on your local system. Instructions on how do this are currently beyond the scope of this project.

# Configure

You need to set the configuration options in config/shared-config.

# Deploy

`kubectl apply -f config/ -R`


# Alternative: microk8s

As an alernative (mostly for local testing), you can run Kubernetes locally and run Arcus there.

`$ sudo snap install microk8s --classic`
`$ microk8s.enable dns`
`$ microk8s.enable storage`
`$ microk8s.kubectl apply -f config/ -R`
`$ microk8s.kubectl exec cassandra-0 --stdin --tty -- '/bin/sh' '-c' 'CASSANDRA_KEYSPACE=production CASSANDRA_REPLICATION=1 /usr/bin/cassandra-provision'`
`$ kubectl apply -f https://raw.githubusercontent.com/google/metallb/v0.7.3/manifests/metallb.yaml`
`$ kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/mandatory.yaml`
`$ kubectl apply -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.7/deploy/manifests/cert-manager.yaml --validate=false`
