# Google Cloud Metrics for Swift

This package provides a Swift implementation for metrics with the Google Cloud Platform ([Cloud Monitoring](https://cloud.google.com/monitoring/docs)). It's built to integrate with the official [Swift Metrics](https://github.com/apple/swift-metrics).

## Example usage

```swift
import GoogleCloudMetrics
import GoogleCloudServiceContext
import Logging
import Metrics
import ServiceLifecycle

let logger = Logger(label: "app")

let serviceContextResolver = GoogleServiceContextResolver()
let metrics = try GoogleCloudMetricsFactory()
MetricsSystem.bootstrap(metrics)

let serviceGroup = ServiceGroup(
  services: [serviceContextResolver, metrics, /* your other services */],
  gracefulShutdownSignals: [.sigterm],
  logger: logger
)
try await serviceGroup.run()
```

Metrics are aggregated in memory and exported every 60 seconds (configurable with `exportInterval`, at least 5 seconds), plus once more during graceful shutdown. The final export is limited by `shutdownTimeout` (8 seconds by default, to fit within the 10 seconds Cloud Run waits after `SIGTERM`).

This will automatically authenticate with Google Cloud. See [Google Cloud Auth for Swift](https://github.com/rosecoder/google-cloud-auth-swift) for supported authentication methods. The identity needs the `roles/monitoring.metricWriter` role.

### Project and resource

The project is resolved in this order: the `projectID` argument, the `GCP_PROJECT_ID` or `GOOGLE_CLOUD_PROJECT` environment variables, the project of the service account in `GOOGLE_APPLICATION_CREDENTIALS`, and finally the metadata server. The metadata server (used on Cloud Run, GKE and Compute Engine) is only queried when a `GoogleServiceContextResolver` is running, so add it to the same `ServiceGroup` as above.

All time series are written with a `generic_task` monitored resource:

| Label | Value |
|---|---|
| `location` | Region from the service context, or `global` |
| `namespace` | `default` |
| `job` | Service name (`K_SERVICE`, `CLOUD_RUN_JOB`, `KUBERNETES_CONTAINER_NAME` or `APP_NAME`), or the process name |
| `task_id` | Instance ID followed by the process ID |

Cloud Monitoring rejects points written to the same time series from more than one process, so `task_id` must be unique per process. On GKE, the instance ID is the node's unless `KUBERNETES_POD_NAME` is set, so the pod's hostname is used instead. You can expose the pod name with the Downward API:

```yaml
env:
  - name: KUBERNETES_POD_NAME
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
```

Pass `resource` to use another monitored resource.

## How metrics are exported

Each metric label becomes a metric type prefixed with `custom.googleapis.com/` (configurable with `metricTypePrefix`), and dimensions become metric labels.

| Swift Metrics | Cloud Monitoring |
|---|---|
| `Counter` | Cumulative `INT64` |
| `FloatingPointCounter` | Cumulative `DOUBLE` |
| `Meter`, `Gauge` | Gauge `DOUBLE` |
| `Recorder` (aggregating) | Cumulative `DISTRIBUTION` |
| `Timer` | Cumulative `DISTRIBUTION`, in milliseconds |

Distribution buckets can be configured with `timerBuckets` and `recorderBuckets`, using `.linear`, `.exponential` or `.explicit`. A distribution has at most 200 buckets, including the underflow and overflow buckets.

Names are sanitized to what Cloud Monitoring accepts: characters other than letters, digits, `_`, `.` and `/` in labels, and other than letters, digits and `_` in dimension keys, are replaced with `_`. Metrics which end up with the same name and dimensions share the same time series, so `http-requests` and `http_requests` are aggregated together. If metrics of different kinds (for example a `Counter` and a `Gauge`) share a name, only the first one created is exported and a warning is logged. At most 30 dimensions are exported per metric.

Destroyed metrics are exported one last time before they are removed.

Every unique combination of dimension values is a separate time series in Cloud Monitoring, and is billed as such. Avoid dimensions with unbounded values, like user IDs.

## Querying

Metrics can be queried with PromQL in Metrics Explorer, where `.` and `/` in metric types are replaced with `_`:

```promql
rate(custom_googleapis_com:http_requests{monitored_resource="generic_task"}[5m])
```

## Development

gRPC code is generated from [googleapis](https://github.com/googleapis/googleapis), included as a submodule:

```sh
git submodule update --init
bash Scripts/generate-grpc.bash
```

Integration tests run when authenticated with Google Cloud, and write to and read from Cloud Monitoring in the resolved project. The identity needs `roles/monitoring.metricWriter` and `roles/monitoring.viewer`.
