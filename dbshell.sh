#!/bin/bash

KUBECTL=${KUBECTL:-kubectl}
$KUBECTL exec --stdin --tty cassandra-0 /bin/bash -- /opt/cassandra/bin/cqlsh localhost
