# shellcheck shell=bash
# Load all function modules
_funcs_dir="${BASH_SOURCE[0]%/*}"
# shellcheck source=script/install.sh
. "${_funcs_dir}/install.sh"
# shellcheck source=script/config.sh
. "${_funcs_dir}/config.sh"
# shellcheck source=script/deploy.sh
. "${_funcs_dir}/deploy.sh"
# shellcheck source=script/status.sh
. "${_funcs_dir}/status.sh"
# shellcheck source=script/update.sh
. "${_funcs_dir}/update.sh"
# shellcheck source=script/backup.sh
. "${_funcs_dir}/backup.sh"
# shellcheck source=script/route53.sh
. "${_funcs_dir}/route53.sh"
# shellcheck source=script/validate.sh
. "${_funcs_dir}/validate.sh"
# shellcheck source=script/grafana.sh
. "${_funcs_dir}/grafana.sh"
# shellcheck source=script/node.sh
. "${_funcs_dir}/node.sh"
# shellcheck source=script/notify.sh
. "${_funcs_dir}/notify.sh"
unset _funcs_dir
