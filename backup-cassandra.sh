#!/bin/bash

DATE=$(date '+%Y-%m-%d_%H-%M-%S')

/snap/bin/microk8s.kubectl exec --stdin --tty cassandra-0 /bin/tar zcvf "/data/cassandra-${DATE}.tar.gz" cassandra
/snap/bin/microk8s.kubectl cp cassandra-0:/data/"cassandra-${DATE}.tar.gz" .
/snap/bin/microk8s.kubectl exec --stdin --tty cassandra-0 /bin/rm "/data/cassandra-${DATE}.tar.gz"

