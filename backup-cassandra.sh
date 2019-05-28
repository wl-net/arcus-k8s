#!/bin/bash

DATE=$(date '+%Y-%m-%d_%H-%M-%S')

$KUBECTL exec --stdin --tty cassandra-0 /bin/tar zcvf "/data/cassandra-${DATE}.tar.gz" cassandra
$KUBECTL cp cassandra-0:/data/"cassandra-${DATE}.tar.gz" .
$KUBECTL exec --stdin --tty cassandra-0 /bin/rm "/data/cassandra-${DATE}.tar.gz"

