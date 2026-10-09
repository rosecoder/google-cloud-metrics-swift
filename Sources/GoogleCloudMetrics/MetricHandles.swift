import CoreMetrics
import Foundation
import Synchronization

/// A handler returned for each `make*` call. The registry counts live handles to know whether a
/// metric is still referenced, so handles must never be deallocated while holding the registry's
/// lock.
protocol LeasedHandle: AnyObject {

  /// Releases the handle's lease and marks it as destroyed.
  func destroy()
}

final class CounterHandle: CounterHandler, LeasedHandle {

  let metric: CounterMetric
  private let lease: Lease

  init(metric: CounterMetric, registry: MetricsRegistry?) {
    self.metric = metric
    self.lease = Lease(metric: metric, registry: registry)
  }

  func increment(by amount: Int64) {
    metric.increment(by: amount)
  }

  func reset() {
    metric.reset()
  }

  func destroy() {
    lease.release(destroy: true)
  }
}

final class FloatingPointCounterHandle: FloatingPointCounterHandler, LeasedHandle {

  let metric: FloatingPointCounterMetric
  private let lease: Lease

  init(metric: FloatingPointCounterMetric, registry: MetricsRegistry?) {
    self.metric = metric
    self.lease = Lease(metric: metric, registry: registry)
  }

  func increment(by amount: Double) {
    metric.increment(by: amount)
  }

  func reset() {
    metric.reset()
  }

  func destroy() {
    lease.release(destroy: true)
  }
}

final class MeterHandle: MeterHandler, LeasedHandle {

  let metric: GaugeMetric
  private let lease: Lease

  init(metric: GaugeMetric, registry: MetricsRegistry?) {
    self.metric = metric
    self.lease = Lease(metric: metric, registry: registry)
  }

  func set(_ value: Int64) {
    metric.set(value)
  }

  func set(_ value: Double) {
    metric.set(value)
  }

  func increment(by amount: Double) {
    metric.increment(by: amount)
  }

  func decrement(by amount: Double) {
    metric.decrement(by: amount)
  }

  func destroy() {
    lease.release(destroy: true)
  }
}

final class RecorderHandle: RecorderHandler, LeasedHandle {

  let metric: any RecorderHandler & ExportableMetric
  private let lease: Lease

  init(metric: any RecorderHandler & ExportableMetric, registry: MetricsRegistry?) {
    self.metric = metric
    self.lease = Lease(metric: metric, registry: registry)
  }

  func record(_ value: Int64) {
    metric.record(value)
  }

  func record(_ value: Double) {
    metric.record(value)
  }

  func destroy() {
    lease.release(destroy: true)
  }
}

final class TimerHandle: TimerHandler, LeasedHandle {

  let metric: DistributionMetric
  private let lease: Lease

  init(metric: DistributionMetric, registry: MetricsRegistry?) {
    self.metric = metric
    self.lease = Lease(metric: metric, registry: registry)
  }

  func recordNanoseconds(_ duration: Int64) {
    metric.recordNanoseconds(duration)
  }

  func destroy() {
    lease.release(destroy: true)
  }
}

/// Releases a handle's reference to its metric exactly once, when the handle is destroyed or
/// deallocated. Metrics registered with a conflicting kind aren't leased and have no registry.
struct Lease: ~Copyable, Sendable {

  private let metric: any ExportableMetric
  private let registry: MetricsRegistry?
  private let isReleased = Atomic(false)

  init(metric: any ExportableMetric, registry: MetricsRegistry?) {
    self.metric = metric
    self.registry = registry
  }

  deinit {
    release(destroy: false)
  }

  func release(destroy: Bool) {
    guard let registry,
      isReleased.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged
    else {
      return
    }
    registry.release(metric, destroy: destroy)
  }
}
