# arcus-k8
Arcus in Kubernetes (on-prem or GKE)

# Prerequisites

You either need a Google Cloud account (see below) or a dedicated system with 12GB or more of RAM, and 15GB of disk space.

# Run locally (microk8s)

Simply execute:

`./setup-local.sh`

It will takes about 5-10 minutes for everything to come up. When `microk8s.kubectl get pods` shows a list of pods in the running or completed state, you are good to go.

# In Google Cloud

You need to have a Google Cloud account, and have configured gcloud and docker on your local system. Instructions on how do this are currently beyond the scope of this project.


