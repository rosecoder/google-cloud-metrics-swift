import CoreMetrics
import Foundation
import Logging
import SwiftProtobuf
import Synchronization
import Testing

@testable import GoogleCloudMetrics

@Suite struct IdleExpirationTests {

  let writer = FakeTimeSeriesWriter()
  let clock = TestClock()

  @Test func inlineCounterIsExportedUntilIdleAndThenRemoved() async throws {
    let factory = makeFactory(
      writer: writer, clock: clock, idleExpiration: IdleExpiration(after: .seconds(120)))

    for _ in 0..<2 {
      Counter(label: "requests", factory: factory).increment()
      clock.advance(by: 60)
      try await factory.export()
    }
    for _ in 0..<4 {
      clock.advance(by: 60)
      try await factory.export()
    }

    #expect(writer.int64Values(type: "requests") == [1, 2, 2, 2])
    let endTimes = writer.writtenTimeSeries.map { $0.points[0].interval.endTime.date }
    #expect(endTimes.last == clock.now.addingTimeInterval(-120))
  }

  @Test func storedCounterIsNeverRemoved() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    let counter = Counter(label: "requests", factory: factory)
    counter.increment()
    for _ in 0..<24 {
      clock.advance(by: 3600)
      try await factory.export()
    }
    withExtendedLifetime(counter) {}

    #expect(writer.int64Values(type: "requests") == Array(repeating: 1, count: 24))
  }

  @Test(arguments: [0, -30])
  func recreatedCounterStartsAfterPreviousEndTime(clockStep: TimeInterval) async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    Counter(label: "requests", factory: factory).increment(by: 2)
    clock.advance(by: 60)
    try await factory.export()
    let previousEndTime = clock.now

    clock.advance(by: clockStep)
    Counter(label: "requests", factory: factory).increment(by: 3)
    clock.advance(by: 60)
    try await factory.export()

    let points = writer.writtenTimeSeries.map { $0.points[0] }
    #expect(points.map(\.value.int64Value) == [2, 3])
    #expect(points[0].interval.endTime.date == previousEndTime)
    #expect(points[1].interval.startTime.date > previousEndTime)
    #expect(points[1].interval.startTime.date < points[1].interval.endTime.date)
  }

  @Test(arguments: [true, false])
  func updateBetweenSnapshotAndRemovalKeepsMetric(isDestroyed: Bool) throws {
    let registry = MetricsRegistry(
      logger: Logger(label: "test"),
      idleExpiration: isDestroyed ? nil : IdleExpiration(after: .zero),
      exportInterval: .seconds(60))
    let key = MetricKey(
      kind: .counter, label: "requests", dimensions: [], metricTypePrefix: "custom.googleapis.com/")
    let probe = registry.acquire(key) { key, _ in ProbeMetric(key: key) }.metric
    probe.increment()
    registry.release(probe, destroy: isDestroyed)

    probe.onNextPoint {
      let (metric, isLeased) = registry.acquire(key) { key, _ in ProbeMetric(key: key) }
      #expect(metric === probe)
      #expect(isLeased)
      metric.increment()
      registry.release(metric, destroy: isDestroyed)
    }
    let start = Date(timeIntervalSince1970: 0)
    let first = registry.collect(endingAt: start.addingTimeInterval(60))
    let second = registry.collect(endingAt: start.addingTimeInterval(120))
    let third = registry.collect(endingAt: start.addingTimeInterval(180))

    #expect(first.map(\.point) == [.counter(startTime: start, value: 1)])
    #expect(second.map(\.point) == [.counter(startTime: start, value: 2)])
    #expect(third.isEmpty)
  }

  @Test func zeroExportsOncePerActiveInterval() async throws {
    let factory = makeFactory(
      writer: writer, clock: clock, idleExpiration: IdleExpiration(after: .zero))

    for incrementsPerInterval in [1, 0, 2, 0, 0, 3] {
      for _ in 0..<incrementsPerInterval {
        Counter(label: "requests", factory: factory).increment()
      }
      clock.advance(by: 60)
      try await factory.export()
    }

    #expect(writer.requests.count == 3)
    #expect(writer.int64Values(type: "requests") == [1, 2, 3])
    let startTimes = writer.writtenTimeSeries.map { $0.points[0].interval.startTime }
    #expect(Set(startTimes).count == 3)
  }

  @Test func counterUpdatedAtExportTimeIsKeptUntilExported() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    Counter(label: "requests", factory: factory).increment()
    try await factory.export()
    clock.advance(by: 60)
    try await factory.export()
    clock.advance(by: 60)
    try await factory.export()

    #expect(writer.int64Values(type: "requests") == [1])
  }

  @Test func gaugesAreNotExpiredByDefault() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    Meter(label: "connections", factory: factory).increment(by: 2)
    Gauge(label: "temperature", factory: factory).record(20)
    for _ in 0..<3 {
      clock.advance(by: 60)
      try await factory.export()
    }

    #expect(writer.requests.map(\.timeSeries.count) == [2, 2, 2])
  }

  @Test func gaugesExpireWhenIncluded() async throws {
    let factory = makeFactory(
      writer: writer, clock: clock,
      idleExpiration: IdleExpiration(after: .zero, kinds: [.gauges]))

    let storedMeter = Meter(label: "sessions", factory: factory)
    storedMeter.set(1)
    Meter(label: "connections", factory: factory).increment(by: 2)
    Gauge(label: "temperature", factory: factory).record(20)
    Counter(label: "requests", factory: factory).increment()
    for _ in 0..<3 {
      clock.advance(by: 60)
      try await factory.export()
    }
    withExtendedLifetime(storedMeter) {}

    let types = writer.requests.map { $0.timeSeries.map(\.metric.type).sorted() }
    #expect(
      types == [
        [
          "custom.googleapis.com/connections", "custom.googleapis.com/requests",
          "custom.googleapis.com/sessions", "custom.googleapis.com/temperature",
        ],
        ["custom.googleapis.com/requests", "custom.googleapis.com/sessions"],
        ["custom.googleapis.com/requests", "custom.googleapis.com/sessions"],
      ])
  }

  @Test func withoutIdleExpirationUnreferencedMetricsAreKept() async throws {
    let factory = makeFactory(writer: writer, clock: clock, idleExpiration: nil)

    Counter(label: "requests", factory: factory).increment()
    CoreMetrics.Timer(label: "latency", factory: factory).recordMilliseconds(5)
    for _ in 0..<5 {
      clock.advance(by: 3600)
      try await factory.export()
    }

    #expect(writer.requests.map(\.timeSeries.count) == [2, 2, 2, 2, 2])
  }

  @Test func timerExpiresAndRestartsAfterPreviousEndTime() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    CoreMetrics.Timer(label: "latency", factory: factory).recordMilliseconds(5)
    clock.advance(by: 60)
    try await factory.export()
    let previousEndTime = clock.now
    clock.advance(by: 60)
    try await factory.export()

    CoreMetrics.Timer(label: "latency", factory: factory).recordMilliseconds(7)
    CoreMetrics.Timer(label: "latency", factory: factory).recordMilliseconds(9)
    clock.advance(by: 60)
    try await factory.export()

    let points = writer.writtenTimeSeries.map { $0.points[0] }
    #expect(points.map(\.value.distributionValue.count) == [1, 2])
    #expect(points.map(\.value.distributionValue.mean) == [5, 8])
    #expect(points[1].interval.startTime.date > previousEndTime)
  }

  @Test func recreatedDistributionStartsAfterPreviousEndTime() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    Recorder(label: "payload_size", factory: factory).record(10)
    clock.advance(by: 60)
    try await factory.export()
    let previousEndTime = clock.now

    Recorder(label: "payload_size", factory: factory).record(20)
    clock.advance(by: 60)
    try await factory.export()

    let points = writer.writtenTimeSeries.map { $0.points[0] }
    #expect(points.map(\.value.distributionValue.mean) == [10, 20])
    #expect(points[1].interval.startTime.date > previousEndTime)
  }

  @Test func lastEndTimesArePrunedAfterRetention() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    Counter(label: "requests", factory: factory).increment()
    clock.advance(by: 60)
    try await factory.export()
    #expect(factory.registry.lastEndTimeCount == 1)

    clock.advance(by: 3600)
    try await factory.export()
    #expect(factory.registry.lastEndTimeCount == 1)

    clock.advance(by: 61)
    try await factory.export()
    #expect(factory.registry.lastEndTimeCount == 0)
  }

  @Test func negativeIdleExpirationIsRejected() async {
    await #expect(processExitsWith: .failure) {
      _ = makeFactory(idleExpiration: IdleExpiration(after: .seconds(-1)))
    }
  }

  @Test func concurrentInlineIncrementsAreNeverLost() async throws {
    let factory = makeFactory(writer: writer, clock: clock)
    let isDone = Flag()
    let identities = 50
    let tasks = 50
    let incrementsPerTask = 200

    let collector = Task {
      while !isDone.value {
        clock.advance(by: 1)
        try await factory.export()
        await Task.yield()
      }
    }
    await withTaskGroup(of: Void.self) { group in
      for task in 0..<tasks {
        group.addTask {
          for increment in 0..<incrementsPerTask {
            Counter(
              label: "requests",
              dimensions: [("identity", "\((task + increment) % identities)")],
              factory: factory
            ).increment()
            if increment % 10 == 0 {
              await Task.yield()
            }
          }
        }
      }
    }
    isDone.set()
    try await collector.value
    for _ in 0..<2 {
      clock.advance(by: 1)
      try await factory.export()
    }

    var finalValues: [String: Int64] = [:]
    for timeSeries in writer.writtenTimeSeries {
      let point = timeSeries.points[0]
      let lifetime = "\(timeSeries.metric.labels["identity"]!)@\(point.interval.startTime)"
      finalValues[lifetime] = max(finalValues[lifetime] ?? 0, point.value.int64Value)
    }
    #expect(finalValues.values.reduce(0, +) == Int64(tasks * incrementsPerTask))
    #expect(factory.registry.collect(endingAt: clock.now.addingTimeInterval(1)).isEmpty)
  }
}

private final class ProbeMetric: ExportableMetric {

  private struct State {
    var value: Int64 = 0
    var updateCount: UInt64 = 0
    var onNextPoint: (@Sendable () -> Void)?
  }

  let key: MetricKey

  private let state = Mutex(State())

  init(key: MetricKey) {
    self.key = key
  }

  var updateCount: UInt64 {
    state.withLock { $0.updateCount }
  }

  func increment() {
    state.withLock { state in
      state.value += 1
      state.updateCount += 1
    }
  }

  /// Runs `action` after the value of the next point is read, outside the registry's lock.
  func onNextPoint(_ action: @escaping @Sendable () -> Void) {
    state.withLock { $0.onNextPoint = action }
  }

  func point(endingAt endTime: Date) -> MetricPoint? {
    let (value, onNextPoint) = state.withLock { state in
      defer { state.onNextPoint = nil }
      return (state.value, state.onNextPoint)
    }
    onNextPoint?()
    return .counter(startTime: Date(timeIntervalSince1970: 0), value: value)
  }
}

private final class Flag: Sendable {

  private let isSet = Atomic(false)

  var value: Bool {
    isSet.load(ordering: .acquiring)
  }

  func set() {
    isSet.store(true, ordering: .releasing)
  }
}

extension FakeTimeSeriesWriter {

  fileprivate func int64Values(type: String) -> [Int64] {
    writtenTimeSeries
      .filter { $0.metric.type == "custom.googleapis.com/" + type }
      .map { $0.points[0].value.int64Value }
  }
}
