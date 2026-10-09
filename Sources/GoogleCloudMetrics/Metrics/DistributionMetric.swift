import CoreMetrics
import Foundation
import Synchronization

struct DistributionSnapshot: Equatable, Sendable {
  var count: Int64
  var mean: Double
  var sumOfSquaredDeviation: Double
  var bucketCounts: [Int64]
  let buckets: DistributionBuckets
}

/// Backs both aggregating recorders and timers. Timers are recorded in milliseconds.
final class DistributionMetric: RecorderHandler, TimerHandler, ExportableMetric {

  /// Larger values are dropped, since squaring their deviation from the mean could overflow.
  static let maximumMagnitude = 1e150

  private struct State {
    var snapshot: DistributionSnapshot
    let startTime: Date
    var updateCount: UInt64 = 0
  }

  let key: MetricKey

  private let bounds: [Double]
  private let state: Mutex<State>

  init(key: MetricKey, buckets: DistributionBuckets, startTime: Date) {
    self.key = key
    self.bounds = buckets.bounds
    self.state = Mutex(
      State(
        snapshot: DistributionSnapshot(
          count: 0,
          mean: 0,
          sumOfSquaredDeviation: 0,
          bucketCounts: Array(repeating: 0, count: buckets.bounds.count + 1),
          buckets: buckets
        ),
        startTime: startTime
      ))
  }

  var updateCount: UInt64 {
    state.withLock { $0.updateCount }
  }

  func record(_ value: Int64) {
    record(Double(value))
  }

  func record(_ value: Double) {
    guard value.isFinite, value.magnitude <= Self.maximumMagnitude else {
      return
    }
    let bucketIndex = DistributionBuckets.bucketIndex(for: value, bounds: bounds)
    state.withLock { state in
      // Welford's online algorithm for mean and sum of squared deviation.
      state.snapshot.count += 1
      let delta = value - state.snapshot.mean
      state.snapshot.mean += delta / Double(state.snapshot.count)
      state.snapshot.sumOfSquaredDeviation = min(
        state.snapshot.sumOfSquaredDeviation + delta * (value - state.snapshot.mean),
        .greatestFiniteMagnitude
      )
      state.snapshot.bucketCounts[bucketIndex] += 1
      state.updateCount &+= 1
    }
  }

  func recordNanoseconds(_ duration: Int64) {
    guard duration >= 0 else {
      return
    }
    record(Double(duration) / 1_000_000)
  }

  func point(endingAt endTime: Date) -> MetricPoint? {
    let (snapshot, startTime) = state.withLock { ($0.snapshot, $0.startTime) }
    guard snapshot.count > 0,
      endTime.timeIntervalSince(startTime) >= minimumCumulativeInterval
    else {
      return nil
    }
    return .distribution(startTime: startTime, snapshot)
  }
}
