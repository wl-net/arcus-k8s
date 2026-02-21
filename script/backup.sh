# shellcheck shell=bash
# Backup and restore functions

function backup_config() {
  DATE=$(date '+%Y-%m-%d_%H-%M-%S')
  BACKUP_FILE="arcus-config-backup-${DATE}.tar.gz"

  DIRS=()
  for dir in .config secret overlays/local-production-local overlays/local-production-cluster-local; do
    if [[ -d "${ROOT}/${dir}" ]]; then
      DIRS+=("${dir}")
    fi
  done

  if [[ ${#DIRS[@]} -eq 0 ]]; then
    echo "Nothing to back up — no local configuration directories found."
    exit 1
  fi

  echo "Backing up: ${DIRS[*]}"
  tar -czf "${BACKUP_FILE}" -C "${ROOT}" "${DIRS[@]}"
  echo "Configuration saved to ${BACKUP_FILE}"
}

function backup_cassandra() {
  local date_stamp
  date_stamp=$(date '+%Y-%m-%d_%H-%M-%S')

  echo "Clearing old snapshots..."
  $KUBECTL exec cassandra-0 -- /opt/cassandra/bin/nodetool clearsnapshot
  echo "Taking snapshot..."
  $KUBECTL exec cassandra-0 -- /opt/cassandra/bin/nodetool snapshot -t arcus-backup
  echo "Exporting schema..."
  $KUBECTL exec cassandra-0 -- /bin/bash -c '/usr/bin/cqlsh -e "DESCRIBE SCHEMA" > keyspaces.cqlsh'
  echo "Creating tarball..."
  # shellcheck disable=SC2016
  $KUBECTL exec cassandra-0 -- /bin/bash -c '/bin/tar czf "/data/cassandra-backup.tar.gz" $(find /data/cassandra -type d -name arcus-backup) keyspaces.cqlsh'
  $KUBECTL cp cassandra-0:/data/cassandra-backup.tar.gz "cassandra-${date_stamp}.tar.gz"
  $KUBECTL exec cassandra-0 -- /bin/rm /data/cassandra-backup.tar.gz
  echo "Backup saved to cassandra-${date_stamp}.tar.gz"
}

function restore_cassandra_snapshot() {
  if [[ $# -eq 0 || -z "$1" ]]; then
    echo "Usage: arcuscmd restoredb <backup-file.tar.gz>"
    return 1
  fi
  local file=$1
  if [[ ! -f "$file" ]]; then
    echo "Error: file not found: $file"
    return 1
  fi

  echo "Copying backup to pod..."
  $KUBECTL cp "$file" cassandra-0:/data/cassandra-restore.tar.gz
  echo "Extracting..."
  $KUBECTL exec cassandra-0 -- /bin/mkdir -p /data/restore
  $KUBECTL exec cassandra-0 -- /bin/tar xzf /data/cassandra-restore.tar.gz -C /data/restore
  $KUBECTL exec cassandra-0 -- /bin/rm /data/cassandra-restore.tar.gz
  echo "Applying schema..."
  $KUBECTL exec cassandra-0 -- /bin/bash -c 'cd /data/restore; /usr/bin/cqlsh < /data/restore/keyspaces.cqlsh'
  echo "Loading SSTables..."
  # shellcheck disable=SC2016
  $KUBECTL exec cassandra-0 -- /bin/bash -c 'cd /data/restore; for i in $(find . -type d -name arcus-backup); do cp $i/* $i/../.. && /opt/cassandra/bin/sstableloader -d localhost $(echo $i | sed "s/snapshots\/arcus-backup//"); done'
  $KUBECTL exec cassandra-0 -- /bin/rm -rf /data/restore
  echo "Restore complete. You may need to restart some pods to make the system consistent."
}

function restore_cassandra_full() {
  if [[ $# -eq 0 || -z "$1" ]]; then
    echo "Usage: arcuscmd restoredb-full <backup-file.tar.gz>"
    return 1
  fi
  local file=$1
  if [[ ! -f "$file" ]]; then
    echo "Error: file not found: $file"
    return 1
  fi

  echo "WARNING: This will replace the entire Cassandra data directory and kill the Cassandra process."
  echo "The pod will restart automatically, but there will be downtime."
  local confirm
  prompt confirm "Are you sure you want to continue? [yes/no]:"
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    return 0
  fi

  echo "Copying backup to pod..."
  $KUBECTL cp "$file" cassandra-0:/data/cassandra-restore.tar.gz
  echo "Moving old data directory..."
  $KUBECTL exec cassandra-0 -- /bin/mv /data/cassandra /data/cassandra-old
  echo "Extracting..."
  $KUBECTL exec cassandra-0 -- /bin/tar xzf /data/cassandra-restore.tar.gz
  $KUBECTL exec cassandra-0 -- /bin/rm /data/cassandra-restore.tar.gz
  $KUBECTL exec cassandra-0 -- /bin/sync
  echo "Killing Cassandra process (pod will restart)..."
  $KUBECTL exec cassandra-0 -- /usr/bin/killall java
  echo "Full restore complete. Cassandra will restart with the restored data."
}
