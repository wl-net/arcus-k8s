#!/bin/bash

KUBECTL=${KUBECTL:-kubectl}

$KUBECTL cp $1 cassandra-0:/data/"cassandra-restore.tar.gz"
$KUBECTL exec --stdin --tty cassandra-0 /bin/mv /data/cassandra /data/cassandra-old
$KUBECTL exec --stdin --tty cassandra-0 /bin/tar xzvf "/data/cassandra-restore.tar.gz"
$KUBECTL exec --stdin --tty cassandra-0 /bin/rm "/data/cassandra-restore.tar.gz"
$KUBECTL exec --stdin --tty cassandra-0 /bin/sync
$KUBECTL exec --stdin --tty cassandra-0 /usr/bin/killall java
