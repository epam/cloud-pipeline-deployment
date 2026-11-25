#!/bin/bash
# Entry point for dnf-automatic's reboot_command: runs every script symlinked into
# pre_reboot_scripts/<role>/ for this node's ROLE (terraform creates those symlinks per instance,
# pointing at the actual pre_reboot_scripts/grace_shutdown_*.sh), then reboots. Invoked as
# /var/lib/cloud-pipeline/system-updates/reboot.sh.
set -u

REBOOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_NAME="$(hostname)"

mkdir -p "/opt/system/logs/$NODE_NAME"
exec > >(tee -a "/opt/system/logs/$NODE_NAME/reboot.log") 2>&1
echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) reboot.sh starting on ${NODE_NAME} ==="

source /etc/environment 2>/dev/null || true

case "${ROLE:-master-node}" in
  application-node) _role_dir="application" ;;
  *)                _role_dir="master" ;;
esac

_scripts_dir="${REBOOT_DIR}/pre_reboot_scripts/${_role_dir}"
_results=()
if [ -d "$_scripts_dir" ]; then
  for _script in "$_scripts_dir"/*; do
    [ -x "$_script" ] || continue
    _script_name="$(basename "$_script")"
    echo "--- Running ${_script_name} (role=${_role_dir}) ---"
    if "$_script"; then
      echo "--- ${_script_name} finished successfully ---"
      _results+=("${_script_name}: OK")
    else
      echo "WARNING: ${_script_name} exited with an error, continuing" >&2
      _results+=("${_script_name}: FAILED")
    fi
  done
else
  echo "No scripts directory for role '${_role_dir}' ($_scripts_dir) -- nothing to run."
fi

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) reboot.sh finished ==="
echo "Pre-reboot script summary (role=${_role_dir}):"
if [ "${#_results[@]}" -eq 0 ]; then
  echo "  (none ran)"
else
  for _result in "${_results[@]}"; do
    echo "  - ${_result}"
  done
fi

shutdown -r +1 "Rebooting after applying security updates"
