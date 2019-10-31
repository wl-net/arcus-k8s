#!/bin/bash

KUBECTL=${KUBECTL:-kubectl}

$KUBECTL cp $1 cassandra-0:/data/"cassandra-restore.tar.gz"
#$KUBECTL exec --stdin --tty cassandra-0 /bin/mv /data/cassandra /data/cassandra-old
$KUBECTL exec --stdin --tty cassandra-0 -- /bin/mkdir /data/restore
$KUBECTL exec --stdin --tty cassandra-0 -- /bin/tar xzvf "/data/cassandra-restore.tar.gz" -C /data/restore
$KUBECTL exec --stdin --tty cassandra-0 -- /bin/rm "/data/cassandra-restore.tar.gz"
$KUBECTL exec --stdin --tty cassandra-0 -- /bin/bash -c "cd /data/restore; /usr/bin/cqlsh < /data/restore/keyspaces.cqlsh" 
$KUBECTL exec --stdin --tty cassandra-0 -- /bin/bash -c 'cd /data/restore; for i in $(find . -type d -name arcus-backup); do cp $i/* $i/../.. && /opt/cassandra/bin/sstableloader -d localhost `echo $i | sed "s/snapshots\/arcus-backup//"`; done'

echo "Restore complete. You may need to restart some pods in order to make the system consistent"
