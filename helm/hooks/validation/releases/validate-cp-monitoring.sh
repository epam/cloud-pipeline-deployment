#!/bin/bash
# Validation for cp-monitoring release.
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.

function add_warning { printf 'WARNING: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

HEAPSTER_DATA_PATH=$(jq_val '.monitoring.heapster.elk.dataHostPath // ""')
[ -z "$HEAPSTER_DATA_PATH" ] && add_warning "monitoring.heapster.elk.dataHostPath is empty; heapster ELK data will use the chart default host path"

VM_MONITOR_LOGS_PATH=$(jq_val '.monitoring.vmMonitor.logsHostPath // ""')
[ -z "$VM_MONITOR_LOGS_PATH" ] && add_warning "monitoring.vmMonitor.logsHostPath is empty; vm-monitor logs will use the chart default host path"
