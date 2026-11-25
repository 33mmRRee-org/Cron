#!/usr/bin/env bash
set -euo pipefail
jq -n --arg source "${SOURCE:-all}" '{event_type:"source-mirrors-updated",client_payload:{distribution:$source}}' \
  | gh api -X POST repos/33mmRRee-org/Container/dispatches --input -
