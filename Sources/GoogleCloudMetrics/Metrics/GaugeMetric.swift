import CoreMetrics
import Foundation
import Synchronization

/// Backs both meters and non-aggregating recorders (gauges). Only the latest value is exported.
final class GaugeMetric: MeterHandler, RecorderHandler, ExportableMetric {

  private struct State {
    var value: Double?
    var updateCount: UInt64 = 0
  }

  let key: MetricKey

  private let state = Mutex(State())

  init(key: MetricKey) {
    self.key = key
  }

  var updateCount: UInt64 {
    state.withLock { $0.updateCount }
  }

  func set(_ value: Int64) {
    set(Double(value))
  }

  func set(_ value: Double) {
    guard value.isFinite else {
      return
    }
    state.withLock { state in
      state.value = value
      state.updateCount &+= 1
    }
  }

  /// Ignores amounts which aren't finite and greater than zero, like the `Meter` API requires.
  func increment(by amount: Double) {
    guard amount > 0, amount.isFinite else {
      return
    }
    add(amount)
  }

  /// Ignores amounts which aren't finite and greater than zero, like the `Meter` API requires.
  func decrement(by amount: Double) {
    guard amount > 0, amount.isFinite else {
      return
    }
    add(-amount)
  }

  private func add(_ amount: Double) {
    state.withLock { state in
      let sum = (state.value ?? 0) + amount
      state.value = min(max(sum, -.greatestFiniteMagnitude), .greatestFiniteMagnitude)
      state.updateCount &+= 1
    }
  }

  func record(_ value: Int64) {
    set(Double(value))
  }

  func record(_ value: Double) {
    set(value)
  }

  func point(endingAt endTime: Date) -> MetricPoint? {
    state.withLock { $0.value }.map { .gauge($0) }
  }
}
