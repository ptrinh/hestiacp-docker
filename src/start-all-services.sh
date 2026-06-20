#!/bin/bash
# Start every SysV service that is currently stopped. Used as a best-effort
# catch-all after the explicit service starts in entrypoint.sh.
services=$(service --status-all 2>/dev/null)
while read -r line; do
  if [[ "$line" == *"[ - ]"* ]]; then
    service_name=$(echo "$line" | awk '{print $4}')
    service "$service_name" start >/dev/null 2>&1 || true
  fi
done <<< "$services"
