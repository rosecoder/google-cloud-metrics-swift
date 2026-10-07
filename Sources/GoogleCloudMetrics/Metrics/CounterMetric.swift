import CoreMetrics
import Foundation
import Synchronization

final class CounterMetric: CounterHandler, ExportableMetric {

  private struct State {
    var value: Int64 = 0
    var startTime: Date
    var lastEndTime: Date?
  }

  let key: MetricKey

  private let now: @Sendable () -> Date
  private let state: Mutex<State>

  init(key: MetricKey, startTime: Date, now: @escaping @Sendable () -> Date) {
    self.key = key
    self.now = now
    self.state = Mutex(State(startTime: startTime))
  }

  func increment(by amount: Int64) {
    guard amount > 0 else {
      return
    }
    state.withLock { state in
      let (sum, overflow) = state.value.addingReportingOverflow(amount)
      state.value = overflow ? .max : sum
    }
  }

  func reset() {
    state.withLock { state in
      state.value = 0
      state.startTime = cumulativeStartTime(now: now(), lastEndTime: state.lastEndTime)
    }
  }

  func point(endingAt endTime: Date) -> MetricPoint? {
    state.withLock { state in
      guard endTime.timeIntervalSince(state.startTime) >= minimumCumulativeInterval else {
        return nil
      }
      state.lastEndTime = endTime
      return .counter(startTime: state.startTime, value: state.value)
    }
  }
}

/// Cloud Monitoring requires the start time of a new cumulative interval to be after the end
/// time of the previously written interval.
func cumulativeStartTime(now: Date, lastEndTime: Date?) -> Date {
  guard let lastEndTime else {
    return now
  }
  return max(now, lastEndTime.addingTimeInterval(minimumCumulativeInterval))
}
