#!/bin/bash

DATE=$(date '+%Y-%m-%d_%H-%M-%S')

KEYSPACES='support system production system_distributed history system_auth analytics video system_traces'

$KUBECTL exec --stdin --tty cassandra-0 /opt/cassandra/bin/nodetool clearsnapshot
$KUBECTL exec --stdin --tty cassandra-0 -- /opt/cassandra/bin/nodetool snapshot -t arcus-backup
$KUBECTL exec --stdin --tty cassandra-0 -- /bin/bash -c '/usr/bin/cqlsh -e "DESCRIBE SCHEMA" > keyspaces.cqlsh'
$KUBECTL exec --stdin --tty cassandra-0 -- /bin/bash -c '/bin/tar czf "/data/cassandra-backup.tar.gz" $(find /data/cassandra -type d -name arcus-backup) keyspaces.cqlsh'
$KUBECTL cp cassandra-0:/data/"cassandra-backup.tar.gz" "cassandra-${DATE}.tar.gz"
$KUBECTL exec --stdin --tty cassandra-0 /bin/rm "/data/cassandra-backup.tar.gz"
echo "All done - you need to use the appropriate restore tool which support snapshots."
