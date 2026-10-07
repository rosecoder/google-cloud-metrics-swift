import CoreMetrics
import Foundation
import Synchronization

final class FloatingPointCounterMetric: FloatingPointCounterHandler, ExportableMetric {

  private struct State {
    var value: Double = 0
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

  func increment(by amount: Double) {
    guard amount > 0, amount.isFinite else {
      return
    }
    state.withLock { state in
      state.value = min(state.value + amount, .greatestFiniteMagnitude)
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
      return .floatingPointCounter(startTime: state.startTime, value: state.value)
    }
  }
}
