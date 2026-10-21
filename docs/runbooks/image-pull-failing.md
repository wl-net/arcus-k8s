# Image Pull Failing

Severity **warning** · group Service Health · fires when a container has been in ErrImagePull, ImagePullBackOff or InvalidImageName for 10 minutes.
Rule `image-pull-failing` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

The node cannot download the container's image. During a rollout the old pod
keeps serving, so the service runs the previous version; a pod that was
evicted or a node that was rebuilt has nothing to fall back on, and then
[Workload Unavailable](workload-unavailable.md) fires too.

## Confirm

```bash
kubectl describe pod -n <namespace> <pod>        # Events: the exact pull error
kubectl get pod -n <namespace> <pod> -o jsonpath='{.spec.containers[*].image}'
```

The error says which it is:

- `manifest unknown` / `not found`: the tag does not exist in the registry.
- `unauthorized` / `denied`: the registry needs credentials.
- `dial tcp` / `i/o timeout`: the node cannot reach the registry.

## Fix

- **Tag missing**: image tags live in `config/kustomization.yaml` (`newTag`),
  and `.config/image-version/<service>` for a service moved ahead with
  `deploy --version`. Check the tag exists in the registry
  (`./arcuscmd.sh status` shows each service's build), fix it and
  `./arcuscmd.sh apply`, or `kubectl rollout undo deployment/<app>`.
- **Credentials**: the overlay's `images:` section points some datacenters at
  a private registry; the node needs its pull secret or registry login
  (`/etc/rancher/k3s/registries.yaml`). `sudo k3s crictl pull <image>` on the
  node reproduces the error outside Kubernetes.
- **Network**: `curl -sI https://<registry>/v2/` from the node. DNS and
  outbound HTTPS from the node are what is needed.

## Related alerts

- [Deployment Rollout Stuck](rollout-stuck.md) — the rollout gives up after 10 minutes.
- [Workload Unavailable](workload-unavailable.md) — when no old pod is serving.
