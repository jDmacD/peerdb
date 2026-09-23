#!/bin/sh
# Bootstraps the single-node Garage cluster used for S3 staging:
# cluster layout, the fixed access key, and the staging bucket.
#
# Garage ships as a scratch image with no shell, so this runs from a separate
# container against Garage's admin API. Every step checks current state first,
# so restarting the stack against an existing volume is a no-op.
set -eu

API="http://garage:3903"
AUTH="Authorization: Bearer ${GARAGE_ADMIN_TOKEN}"
KEY_ID="${PEERDB_CLICKHOUSE_AWS_CREDENTIALS_AWS_ACCESS_KEY_ID}"
SECRET="${PEERDB_CLICKHOUSE_AWS_CREDENTIALS_AWS_SECRET_ACCESS_KEY}"
BUCKET="${PEERDB_CLICKHOUSE_AWS_S3_BUCKET_NAME}"
# Capacity is an accounting hint for partition sizing, not a quota or a
# preallocation; Garage refuses to serve until a node has one assigned.
CAPACITY="${GARAGE_NODE_CAPACITY:-100000000000}"

# Not /health: that reports 503 until a layout exists, which is what we are
# about to create.
echo "waiting for garage admin API"
until status=$(curl -sf -H "${AUTH}" "${API}/v2/GetClusterStatus"); do
  sleep 1
done
layout_version=$(echo "$status" | grep -o '"layoutVersion": *[0-9]*' | head -1 | tr -dc '0-9')

if [ "${layout_version:-0}" -eq 0 ]; then
  node=$(echo "$status" | grep -o '"id": *"[0-9a-f]\{64\}"' | head -1 | cut -d'"' -f4)
  echo "assigning layout to node ${node}"
  curl -sf -o /dev/null -H "${AUTH}" -X POST "${API}/v2/UpdateClusterLayout" \
    -d "{\"roles\":[{\"id\":\"${node}\",\"zone\":\"dc1\",\"capacity\":${CAPACITY},\"tags\":[]}]}"
  curl -sf -o /dev/null -H "${AUTH}" -X POST "${API}/v2/ApplyClusterLayout" -d '{"version":1}'
else
  echo "layout already applied (version ${layout_version})"
fi

# Applying a layout is asynchronous: the cluster reports unhealthy until the
# new partitions settle, and key/bucket calls fail while it does. /health is
# meaningful from here on, so gate the rest on it.
echo "waiting for garage to report healthy"
until curl -sf -o /dev/null "${API}/health"; do
  sleep 1
done

if curl -sf -o /dev/null -H "${AUTH}" "${API}/v2/GetKeyInfo?id=${KEY_ID}"; then
  echo "access key ${KEY_ID} already exists"
else
  echo "importing access key ${KEY_ID}"
  curl -sf -o /dev/null -H "${AUTH}" -X POST "${API}/v2/ImportKey" \
    -d "{\"accessKeyId\":\"${KEY_ID}\",\"secretAccessKey\":\"${SECRET}\",\"name\":\"peerdb\"}"
fi

bucket_info=$(curl -sf -H "${AUTH}" "${API}/v2/GetBucketInfo?globalAlias=${BUCKET}" || true)
if [ -z "$bucket_info" ]; then
  echo "creating bucket ${BUCKET}"
  bucket_info=$(curl -sf -H "${AUTH}" -X POST "${API}/v2/CreateBucket" \
    -d "{\"globalAlias\":\"${BUCKET}\"}")
else
  echo "bucket ${BUCKET} already exists"
fi
bucket_id=$(echo "$bucket_info" | grep -o '"id": *"[0-9a-f]\{64\}"' | head -1 | cut -d'"' -f4)

echo "granting ${KEY_ID} access to ${BUCKET}"
curl -sf -o /dev/null -H "${AUTH}" -X POST "${API}/v2/AllowBucketKey" \
  -d "{\"bucketId\":\"${bucket_id}\",\"accessKeyId\":\"${KEY_ID}\",\"permissions\":{\"read\":true,\"write\":true,\"owner\":true}}"

echo "garage ready: bucket ${BUCKET} writable by ${KEY_ID}"
