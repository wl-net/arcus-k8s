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

First install microk8s (you may need to install snap if you haven't already)

`$ sudo snap install microk8s --classic`

Then enable the DNS and storage components
```
$ microk8s.enable dns
$ microk8s.enable storage
```
Apply the configuration: 

`$ microk8s.kubectl apply -f config/ -R`

And provision the production configuration:
```
$ microk8s.kubectl exec cassandra-0 --stdin --tty -- '/bin/sh' '-c' 'CASSANDRA_KEYSPACE=production CASSANDRA_REPLICATION=1 /usr/bin/cassandra-provision'
```

It will takes about 5-10 minutes for everything to come up. When `microk8s.kubectl get pods` shows a list of pods in the running or completed state, you are good to go.

