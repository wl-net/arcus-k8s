#!/bin/bash


/snap/bin/microk8s.kubectl cp $1 cassandra-0:/data/"cassandra-restore.tar.gz"
/snap/bin/microk8s.kubectl exec --stdin --tty cassandra-0 /bin/tar xzvf "/data/cassandra-restore.tar.gz" 
/snap/bin/microk8s.kubectl exec --stdin --tty cassandra-0 /bin/rm "/data/cassandra-restore.tar.gz"
/snap/bin/microk8s.kubectl exec --stdin --tty cassandra-0 /bin/sync
/snap/bin/microk8s.kubectl exec --stdin --tty cassandra-0 /usr/bin/killall java
