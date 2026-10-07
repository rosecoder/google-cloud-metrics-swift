import Foundation
import SwiftProtobuf

enum TimeSeriesEncoder {

  static func encode(
    _ snapshot: MetricSnapshot,
    endTime: Date,
    resource: MonitoredResource
  ) -> Google_Monitoring_V3_TimeSeries {
    .with {
      $0.metric = .with {
        $0.type = snapshot.key.metricType
        $0.labels = snapshot.key.labels
      }
      $0.resource = .with {
        $0.type = resource.type
        $0.labels = resource.labels
      }
      $0.points = [point(snapshot.point, endTime: endTime)]
      switch snapshot.point {
      case .counter:
        $0.metricKind = .cumulative
        $0.valueType = .int64
      case .floatingPointCounter:
        $0.metricKind = .cumulative
        $0.valueType = .double
      case .gauge:
        $0.metricKind = .gauge
        $0.valueType = .double
      case .distribution:
        $0.metricKind = .cumulative
        $0.valueType = .distribution
      }
      if snapshot.key.kind == .timer {
        $0.unit = "ms"
      }
    }
  }

  private static func point(_ point: MetricPoint, endTime: Date) -> Google_Monitoring_V3_Point {
    .with {
      switch point {
      case .counter(let startTime, let value):
        $0.interval = interval(startTime: startTime, endTime: endTime)
        $0.value = .with { $0.int64Value = value }
      case .floatingPointCounter(let startTime, let value):
        $0.interval = interval(startTime: startTime, endTime: endTime)
        $0.value = .with { $0.doubleValue = value }
      case .gauge(let value):
        $0.interval = interval(startTime: nil, endTime: endTime)
        $0.value = .with { $0.doubleValue = value }
      case .distribution(let startTime, let snapshot):
        $0.interval = interval(startTime: startTime, endTime: endTime)
        $0.value = .with { $0.distributionValue = distribution(snapshot) }
      }
    }
  }

  private static func interval(startTime: Date?, endTime: Date) -> Google_Monitoring_V3_TimeInterval
  {
    .with {
      if let startTime {
        $0.startTime = Google_Protobuf_Timestamp(date: startTime)
      }
      $0.endTime = Google_Protobuf_Timestamp(date: endTime)
    }
  }

  static func distribution(_ snapshot: DistributionSnapshot) -> Google_Api_Distribution {
    .with {
      $0.count = snapshot.count
      $0.mean = snapshot.mean
      $0.sumOfSquaredDeviation = snapshot.sumOfSquaredDeviation
      $0.bucketOptions = bucketOptions(snapshot.buckets)
      // Trailing zero counts may be omitted and are then assumed to be zero.
      let lastNonZeroIndex = snapshot.bucketCounts.lastIndex(where: { $0 != 0 }) ?? -1
      $0.bucketCounts = Array(snapshot.bucketCounts[...lastNonZeroIndex])
    }
  }

  private static func bucketOptions(_ buckets: DistributionBuckets)
    -> Google_Api_Distribution.BucketOptions
  {
    .with {
      switch buckets.layout {
      case .linear(let count, let width, let offset):
        $0.linearBuckets = .with {
          $0.numFiniteBuckets = Int32(count)
          $0.width = width
          $0.offset = offset
        }
      case .exponential(let count, let growthFactor, let scale):
        $0.exponentialBuckets = .with {
          $0.numFiniteBuckets = Int32(count)
          $0.growthFactor = growthFactor
          $0.scale = scale
        }
      case .explicit:
        $0.explicitBuckets = .with {
          $0.bounds = buckets.bounds
        }
      }
    }
  }
}
