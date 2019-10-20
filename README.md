# arcus-k8
Arcus in Kubernetes (on-prem or in the cloud)

This project contains configuration and scripts to support running Arcus Smart Home in Kubernetes.

# Prerequisites

You either access to a Kubernetes environment, or suitable bare metal to run one on. You should have 12GB or more of RAM, and at least 15GB of disk space. In order to obtain browser-trusted certificates, you will need to have Arcus publicly accessible, on a well known port (80/443). Using self-signed certificates is not recommended, and will not be supported by the iOS or Android applications (outside of modifying the trust store yourself).

In order to create an account, you will need to have a smarty streets account (for address verification).

For notifications, you must create a Twilio and Sendgrid account. APNS and GCM support is disabled by default and must be configured if desired. Typically this also requires that you distribute and side-load the app onto you device.

# Update Policy

Kubernetes is a fast-moving environment. As a result, only the latest version is currently supported. In order to get security updates, you should roll your containers on a frequent basis, depending on your risk tolerance. It is recommended that you do this at least weekly. In the intest of security future releases of Arcus may "expire" such that they will not work if you forget to patch.

# Run locally (microk8s)

**Note**: although microk8s works on multiple linux distributions, the script will currently only work on debian based systems, and has only been tested on Ubuntu 18.04. 

Simply execute:

`./arcuscmd.sh setup`

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

Once your network is setup, and you are able to access Arcus (and get a certificate warning from the untrusted LetsEncrypt Staging CA), then it's time to setup a production certificate. Currently, this is done by making changes to config/service/ui-service-ingress.yml, although you shouldn't edit this file directly:

Run `./arcuscmd.sh useprodcert`

This will apply the configuration - wait a few minutes. You should no longer see a certificate warning when navigating to the site.

You can use `microk8s.kubectl -n cert-manager logs $(/snap/bin/microk8s.kubectl get pod -n cert-manager | grep cert-manager- | awk '{print $1}' | grep -v cainject | grep -v webhook) -f` to view the logs for cert-manager if you don't get a certificate.

## Setting up the Hub Trust Store

Unfortunately, the hub-bridge doesn't work out of the box because it expects a Java Key Store, something we can't provide with cert-manager. Arcusplatform now supports PKCS#8 keys as well (via netty's internal support for PKCS#8), but the private key that cert-manager generates is in PKCS#1 format. As a result, you'll have to manually convert the private key to PKCS#1.

This can be acomplished by running `./setup-hubkeystore.sh` once you have production certificates (see above).

## Viewing pod status

`kubectl describe pod $POD`

where $POD is something like "alarm-service"

## Backups

The only critical persistent system (at least for the minimum use case) is cassandra. Utility scripts have been provided to assist with backing up and restoring cassandra. Typically you'd want to use snapshots to backup cassandra, however in low-activity use cases like Arcus, you can also just make a tarball of the working directory and restore it.

## Troubleshooting

TIP: you may want to create an alias so that kubectl works, e.g. `alias kubectl=microk8s.kubectl`. It is recommended that you read through https://kubernetes.io/docs/reference/kubectl/cheatsheet/

### View pod log

`kubectl log kafka-0 kafka`
`kubectl log casandra-0 casandra`

## Adjusting configuration

The first time you setup Arcus, new secrets will be stored in the secrets directory. Once you have completed `./arcuscmd.sh setup`, feel free to adjust any of these secrets to your needs, and further uses of the setup tools in `./arcuscmd.sh` will not cause you to loose your secrets.

You can also adjust the configuration in overlays/local-production-local/, however your changes will be lost if you run `./arcuscmd.sh apply`.

## Updating

First update your local copy with `git pull` or the equivalent arcuscmd command:

`./arcuscmd.sh update`

Then apply the new configuration:

To install updates for Kubernetes components like cert-manager, do:

`./arcuscmd.sh install`

NOTE: this make take some time, as pods terminate and restart.

To update arcus configuration, do:

`./arcuscmd.sh apply`

It is generally recommended to update both at the same time - if you do not update the Kubernetes components for an extended period of time, the may no longer be supported with a newer Arcus configuration.
## Starting over

If you'd like to start over (including wiping any data, or configuration):

`microk8s.reset`

If you experience difficulties (like microk8s.reset hanging), then you may also need to uninstall microk8s:

`snap remove microk8s`

# In Google Cloud

You need to have a Google Cloud account, and have configured gcloud and docker on your local system. Instructions on how do this are currently beyond the scope of this project.


