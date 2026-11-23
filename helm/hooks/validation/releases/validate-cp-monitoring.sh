#!/bin/bash
# Validation for cp-monitoring release.
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.

function add_error   { printf 'ERROR: %s\n' "$1"; }
function add_warning { printf 'WARNING: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

# The chart defaults, where the values do not set them. `// default` would also replace an explicit false.
HEAPSTER_ENABLED=$(jq_val 'if .monitoring.heapster.enabled == null then false else .monitoring.heapster.enabled end')
COLLECTOR_ENABLED=$(jq_val 'if .monitoring.metricsCollector.enabled == null then true else .monitoring.metricsCollector.enabled end')
COLLECTOR_INDEX=$(jq_val '.monitoring.metricsCollector.index // ""')
if [ "$HEAPSTER_ENABLED" = "true" ] && [ "$COLLECTOR_ENABLED" = "true" ] \
    && { [ -z "$COLLECTOR_INDEX" ] || [ "$COLLECTOR_INDEX" = "heapster" ]; }; then
  add_error "monitoring.heapster.enabled and monitoring.metricsCollector.enabled would both write into the heapster-* indices: set monitoring.metricsCollector.index (e.g. cp-metrics-collector) to compare the two, or set monitoring.heapster.enabled: false"
fi
case "$COLLECTOR_INDEX" in
  heapster-*) add_error "monitoring.metricsCollector.index='$COLLECTOR_INDEX' must not start with heapster-: the API takes such an index for a day of heapster's and cannot parse its date" ;;
esac

HEAPSTER_DATA_PATH=$(jq_val '.monitoring.heapster.elk.dataHostPath // ""')
[ -z "$HEAPSTER_DATA_PATH" ] && add_warning "monitoring.heapster.elk.dataHostPath is empty; heapster ELK data will use the chart default host path"

VM_MONITOR_LOGS_PATH=$(jq_val '.monitoring.vmMonitor.logsHostPath // ""')
[ -z "$VM_MONITOR_LOGS_PATH" ] && add_warning "monitoring.vmMonitor.logsHostPath is empty; vm-monitor logs will use the chart default host path"
