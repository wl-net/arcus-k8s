# arcus-k8
Arcus in Kubernetes (on-prem or GKE)

# Prerequisites

You either need a Google Cloud account (see below) or a dedicated system with 12GB or more of RAM, and 15GB of disk space.

# Run locally (microk8s)

Simply execute:

`./setup-local.sh`

You will be prompted to answer some questions, including the credentials for SmartyStreets (which you will need to use to satisfy the requirement to verify your address). For instructions around setting up networking, see below:

If something fails, wait a few minutes and try again.

It will takes about 5-10 minutes for everything to come up. When `microk8s.kubectl get pods` shows a list of pods in the running or completed state, you are good to go.

## Configuring networking

In order to Access the Arcus UI and connect a hub, you will need to configure your network. You have some options when it comes to this. If you are operating in a home environment (e.g. you have NAT and you're behind a gateway), then you have Arcus run a "LoadBalancer" on your local network. For this configuration, you will need to exclude a region of your network from DHCP. For example, if you are using the 192.168.1.1/24 subnet, then you should configure DHCP to assign addresses between 192.168.1.2-192.168.150, and use 192.168.151-192.168.155 for Arcus.

Once you have configured this, and Arcus is running you should check to see which IP addresses in that space are actually being used, e.g.

```
$ microk8s.kubectl get service
NAME                    TYPE           CLUSTER-IP       EXTERNAL-IP   PORT(S)                                                                      AGE
cassandra-service       NodePort       10.152.183.225   <none>        7000:31287/TCP,7001:31914/TCP,7199:32251/TCP,9042:32178/TCP,9160:31262/TCP   27h
client-bridge-service   NodePort       10.152.183.68    <none>        80:31803/TCP                                                                 27h
hub-bridge-service      LoadBalancer   10.152.183.14    172.16.6.1    8082:31804/TCP                                                               6h1m
kafka-service           NodePort       10.152.183.250   <none>        9092:30997/TCP                                                               27h
kubernetes              ClusterIP      10.152.183.1     <none>        443/TCP                                                                      27h
ui-server-service       NodePort       10.152.183.88    <none>        80:30787/TCP                                                                 27h
zookeeper-service       NodePort       10.152.183.132   <none>        2181:30849/TCP                                                               27h
```

This shows that 172.16.6.1 is the IP address of our hub-bridge service (listening on port 8082).

```
$ microk8s.kubectl get service -n ingress-nginx
NAME            TYPE           CLUSTER-IP       EXTERNAL-IP   PORT(S)                      AGE
ingress-nginx   LoadBalancer   10.152.183.146   172.16.6.0    80:31535/TCP,443:32684/TCP   27h
```

This shows that 172.16.6.0 is the IP address of the ui-service and client-bridge services (via nginx proxy). 

It's beyond the scope of this document to describe how to configure your network, but at a high level you will need to forward traffic to these ports (e.g. port forwarding)

Example (note, you must replace GATEWAY_IP accordingly):

```
iptables -t nat -A PREROUTING -p tcp -d GATEWAY_IP --dport 8082 -j DNAT --to-destination 172.16.6.1:8082
iptables -t nat -A PREROUTING -p tcp -d GATEWAY_IP --dport 443 -j DNAT --to-destination 172.16.6.0:443
iptables -t nat -A PREROUTING -p tcp -d GATEWAY_IP --dport 8- -j DNAT --to-destination 172.16.6.0:80
iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE # replace with whatever has the 172.16.6.0 subnet
iptables -P FORWARD ACCEPT
sysctl -w net.ipv4.ip_forward=1
```

Or configure something similar in your router.

For cloud hosting, this is very similar, but you can use the 127.0.0.1/24 subnet instead, e.g. 172.0.0.5-127.0.10

## Using a production certificate

Once your network is setup, and you are able to access Arcus (and get a certificate warning from the untrusted LetsEncrypt Staging CA), then it's time to setup a production certificate. Currently, this is done by making changes to config/service/ui-service-ingress.yml:

1. Search for the line `certmanager.k8s.io/cluster-issuer: "letsencrypt-staging"` and change "staging" to "production"
2. Change secretName from nginx-staging-tls to nginx-production-tls

Now apply the configuration (either re-run setup-local, or just `microk8s.kubectl apply -f config/service/ui-service-ingress.yml`) and wait a few minutes. You should no longer see a certificate warning when navigating to the site.

You can use `microk8s.kubectl -n cert-manager logs $(/snap/bin/microk8s.kubectl get pod -n cert-manager | grep cert-manager- | awk '{print $1}' | grep -v cainject | grep -v webhook) -f` to view the logs for cert-manager if you don't get a certificate.

## Setting up the Hub Trust Store

Unfortunately, the hub-bridge doesn't work out of the box because it expects a Java Key Store, something we can't provide with cert-manager. The wlnet fork of arcusplatform currently has added features to support PKCS#8 keys as well (via netty's internal support for PKCS#8), but the private key that cert-manager generates is in PKCS#1 format. As a result, you'll have to manually convert the private key to PKCS#1.

This can be acomplished by running `./setup-hubkeystore.sh` once you have production certificates (see above).

## Viewing pod status

`T describe pod $POD`

where $POD is something like "alarm-service"

## Troubleshooting

TIP: you may want to create an alias so that kubectl works, e.g. `alias kubectl=microk8s.kubectl`. It is recommended that you read through https://kubernetes.io/docs/reference/kubectl/cheatsheet/

### View pod log

`kubectl log kafka-0 kafka`
`kubectl log casandra-0 casandra`

## Adjusting configuration

The first time you setup Arcus, new secrets will be stored in the secrets directory. Once you have completed ./setup-local.sh, feel free to adjust any of these secrets to your needs, and further uses of `./setup-local.sh` will not cause you to loose your secrets.

You can also adjust the configuration in overlays/local-production-local/, however your changes will be lost if you run ./setup-local.sh.

## Starting over

If you'd like to start over (including wiping any data, or configuration):

`microk8s.reset`

If you experience difficulties (like microk8s.reset hanging), then you may also need to uninstall microk8s:

`snap remove microk8s`

# In Google Cloud

You need to have a Google Cloud account, and have configured gcloud and docker on your local system. Instructions on how do this are currently beyond the scope of this project.


