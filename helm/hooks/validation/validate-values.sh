#!/bin/bash
# Pre-deploy validation of values.yaml (helmfile prepare hook). Args: VALUES_FILE
set -euo pipefail

VALUES_FILE="${1:-}"
[ -z "$VALUES_FILE" ] && { echo "ERROR: Usage: $0 <values-file>"; exit 1; }
[ -f "$VALUES_FILE" ] || { echo "ERROR: Values file not found: $VALUES_FILE"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASES_DIR="$SCRIPT_DIR/releases"
echo "Validating $VALUES_FILE ..."

for cmd in jq; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required but not installed"; exit 1; }
done

# ---------------------------------------------------------------------------
# YAML → JSON
# Prefer vendored yq at helm/yq, then system yq, then python3+PyYAML.
# ---------------------------------------------------------------------------
YQ_BIN=""
if [ -x "$SCRIPT_DIR/../../yq" ]; then
  YQ_BIN="$SCRIPT_DIR/../../yq"
elif command -v yq >/dev/null 2>&1; then
  YQ_BIN="yq"
fi

VALUES_JSON=""
if [ -n "$YQ_BIN" ]; then
  if ! VALUES_JSON=$("$YQ_BIN" eval -o=json '.' "$VALUES_FILE" 2>&1); then
    echo "ERROR: Failed to parse $VALUES_FILE as YAML (yq): $VALUES_JSON"
    exit 1
  fi
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  if ! VALUES_JSON=$(python3 -c \
      'import yaml,sys,json; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' \
      "$VALUES_FILE" 2>&1); then
    echo "ERROR: Failed to parse $VALUES_FILE as YAML (python3): $VALUES_JSON"
    exit 1
  fi
else
  echo "ERROR: No YAML parser found. Vendor yq at helm/yq, install yq in PATH, or install python3+PyYAML."
  exit 1
fi

if ! printf '%s' "$VALUES_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "ERROR: $VALUES_FILE did not parse to a YAML mapping."
  exit 1
fi

export VALUES_JSON

# ---------------------------------------------------------------------------
# Run each release validation script and collect errors/warnings
# ---------------------------------------------------------------------------
ERRORS=()
WARNINGS=()

for script in "$RELEASES_DIR"/validate-*.sh; do
  [ -f "$script" ] || continue
  while IFS= read -r line; do
    case "$line" in
      "ERROR: "*)   ERRORS+=("${line#ERROR: }") ;;
      "WARNING: "*) WARNINGS+=("${line#WARNING: }") ;;
    esac
  done < <(bash "$script" 2>&1 || true)
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo "Validation warnings:"
  for w in "${WARNINGS[@]}"; do
    echo "  WARNING: $w"
  done
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "Validation errors in $VALUES_FILE:"
  for e in "${ERRORS[@]}"; do
    echo "  ERROR: $e"
  done
  echo "Fix the above errors in $VALUES_FILE before deploying."
  exit 1
fi

echo "Validation passed."
