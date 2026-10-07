import CoreMetrics
import Foundation
import Synchronization

/// Backs both meters and non-aggregating recorders (gauges). Only the latest value is exported.
final class GaugeMetric: MeterHandler, RecorderHandler, ExportableMetric {

  let key: MetricKey

  private let value = Mutex<Double?>(nil)

  init(key: MetricKey) {
    self.key = key
  }

  func set(_ value: Int64) {
    set(Double(value))
  }

  func set(_ value: Double) {
    guard value.isFinite else {
      return
    }
    self.value.withLock { $0 = value }
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
    value.withLock { value in
      let sum = (value ?? 0) + amount
      value = min(max(sum, -.greatestFiniteMagnitude), .greatestFiniteMagnitude)
    }
  }

  func record(_ value: Int64) {
    set(Double(value))
  }

  func record(_ value: Double) {
    set(value)
  }

  func point(endingAt endTime: Date) -> MetricPoint? {
    value.withLock { $0 }.map { .gauge($0) }
  }
}
