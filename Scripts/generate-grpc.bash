#!/usr/bin/env bash
set -euo pipefail

swift build --product protoc-gen-grpc-swift-2 -c release
GRPC_PLUGIN="$(swift build -c release --show-bin-path)/protoc-gen-grpc-swift-2"

SOURCES_ROOT="$(pwd)/Sources"

rm -rf ${SOURCES_ROOT}/*/gRPC_generated/*
mkdir -p ${SOURCES_ROOT}/GoogleCloudMetrics/gRPC_generated

cd googleapis/

echo "Generating gRPC code for Cloud Monitoring..."
protoc \
  google/monitoring/v3/metric_service.proto \
  google/monitoring/v3/metric.proto \
  google/monitoring/v3/common.proto \
  google/api/distribution.proto \
  google/api/label.proto \
  google/api/launch_stage.proto \
  google/api/metric.proto \
  google/api/monitored_resource.proto \
  google/rpc/status.proto \
  --plugin=protoc-gen-grpc-swift=${GRPC_PLUGIN} \
  --swift_opt=Visibility=Package \
  --swift_out=${SOURCES_ROOT}/GoogleCloudMetrics/gRPC_generated/ \
  --grpc-swift_opt=Client=true,Server=false \
  --grpc-swift_opt=Visibility=Package \
  --grpc-swift_out=${SOURCES_ROOT}/GoogleCloudMetrics/gRPC_generated/

# Fix conflict of same file name from google/api and google/monitoring/v3
mv "${SOURCES_ROOT}/GoogleCloudMetrics/gRPC_generated/google/api/metric.pb.swift" \
  "${SOURCES_ROOT}/GoogleCloudMetrics/gRPC_generated/google/api/api-metric.pb.swift"

mv "${SOURCES_ROOT}/GoogleCloudMetrics/gRPC_generated/google/api/metric.grpc.swift" \
  "${SOURCES_ROOT}/GoogleCloudMetrics/gRPC_generated/google/api/api-metric.grpc.swift"
