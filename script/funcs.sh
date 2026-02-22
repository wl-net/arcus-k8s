# shellcheck shell=bash
# Load all function modules
# shellcheck source=script/install.sh
# shellcheck source=script/config.sh
# shellcheck source=script/deploy.sh
# shellcheck source=script/status.sh
# shellcheck source=script/update.sh
# shellcheck source=script/backup.sh
# shellcheck source=script/route53.sh
# shellcheck source=script/validate.sh
# shellcheck source=script/grafana.sh
for _f in install config deploy status update backup route53 validate grafana; do
  . "${BASH_SOURCE[0]%/*}/${_f}.sh"
done
unset _f
