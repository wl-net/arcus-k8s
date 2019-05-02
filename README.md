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
`$ kubectl exec cassandra-0 --stdin --tty -- '/bin/sh' '-c' 'CASSANDRA_KEYSPACE=production /usr/bin/cassandra-provision'`

