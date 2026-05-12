#!/bin/bash

PORT=${1:-3000}

for i in {1..10}
do
  STATUS=$(curl -s http://localhost:$PORT/health || true)

  if echo "$STATUS" | grep healthy; then
    echo "Health check passed"
    exit 0
  fi

  echo "Health check failed. Retry $i..."
  sleep 10
done

echo "Application unhealthy"
exit 1
