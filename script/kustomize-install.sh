opsys=linux  # or darwin, or windows
curl -s https://api.github.com/repos/kubernetes-sigs/kustomize/releases |\
  grep browser_download |\
  grep $opsys |\
  cut -d '"' -f 4 |\
  grep /kustomize/v |\
  sort | tail -n 1 |\
  xargs curl -O -L
tar xzf ./kustomize_v*_${opsys}_amd64.tar.gz
chmod u+x kustomize
