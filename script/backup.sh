# shellcheck shell=bash
# Configuration backup

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
