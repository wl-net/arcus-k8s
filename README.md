# arcus-k8
Arcus in Kubernetes (on-prem or GKE)

# Prerequisites

You either need a Google Cloud account (see below) or a dedicated system with 12GB or more of RAM, and 15GB of disk space.

# Run locally (microk8s)

Simply execute:

`./setup-local.sh`

If something fails, wait a few minutes and try again.

It will takes about 5-10 minutes for everything to come up. When `microk8s.kubectl get pods` shows a list of pods in the running or completed state, you are good to go.

## Viewing pod status

`microk8s.kubectl describe pod $POD`

where $POD is something like "alarm-service"

## Starting over

If you'd like to start over (including wiping any data, or configuration):

`microk8s.reset`

If you experience difficult, you may also need to uninstall microk8s:

`snap remove microk8s`

# In Google Cloud

You need to have a Google Cloud account, and have configured gcloud and docker on your local system. Instructions on how do this are currently beyond the scope of this project.


