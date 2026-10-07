import CoreMetrics
import Foundation
import SwiftProtobuf
import Testing

@testable import GoogleCloudMetrics

@Suite struct GoogleCloudMetricsFactoryTests {

  let writer = FakeTimeSeriesWriter()
  let clock = TestClock()

  @Test func counterIsExportedAsCumulativeInt64() async throws {
    let factory = makeFactory(writer: writer, clock: clock)
    let startTime = clock.now

    let counter = Counter(label: "requests", dimensions: [("method", "GET")], factory: factory)
    counter.increment(by: 3)
    counter.increment()
    clock.advance(by: 60)

    try await factory.export()

    let timeSeries = try #require(writer.writtenTimeSeries.first(type: "requests"))
    #expect(timeSeries.metricKind == .cumulative)
    #expect(timeSeries.valueType == .int64)
    #expect(timeSeries.metric.labels == ["method": "GET"])
    #expect(timeSeries.resource.type == "generic_task")
    #expect(timeSeries.resource.labels["task_id"] == "test-task")
    #expect(timeSeries.points.count == 1)
    #expect(timeSeries.points[0].value.int64Value == 4)
    #expect(timeSeries.points[0].interval.startTime == Google_Protobuf_Timestamp(date: startTime))
    #expect(timeSeries.points[0].interval.endTime == Google_Protobuf_Timestamp(date: clock.now))
    #expect(writer.requests.map(\.projectID) == ["test-project"])
  }

  @Test func counterKeepsCumulativeValueAcrossExports() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    let counter = Counter(label: "requests", factory: factory)
    counter.increment(by: 2)
    clock.advance(by: 60)
    try await factory.export()

    counter.increment(by: 3)
    clock.advance(by: 60)
    try await factory.export()

    let values = writer.writtenTimeSeries.map { $0.points[0].value.int64Value }
    #expect(values == [2, 5])
  }

  @Test func counterResetStartsNewInterval() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    let counter = Counter(label: "requests", factory: factory)
    counter.increment(by: 2)
    clock.advance(by: 60)
    let resetTime = clock.now
    counter.reset()
    counter.increment(by: 1)
    clock.advance(by: 60)

    try await factory.export()

    let point = try #require(writer.writtenTimeSeries.first?.points.first)
    #expect(point.value.int64Value == 1)
    #expect(point.interval.startTime == Google_Protobuf_Timestamp(date: resetTime))
  }

  @Test func counterIgnoresNegativeIncrements() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    let counter = Counter(label: "requests", factory: factory)
    counter.increment(by: 2)
    counter.increment(by: -5)
    clock.advance(by: 60)

    try await factory.export()

    #expect(writer.writtenTimeSeries.first?.points.first?.value.int64Value == 2)
  }

  @Test func cumulativeMetricIsSkippedWhenIntervalIsEmpty() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    Counter(label: "requests", factory: factory).increment()

    try await factory.export()

    #expect(writer.requests.isEmpty)
  }

  @Test func sameLabelAndDimensionsShareHandler() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    Counter(label: "requests", dimensions: [("a", "1"), ("b", "2")], factory: factory)
      .increment(by: 1)
    Counter(label: "requests", dimensions: [("b", "2"), ("a", "1")], factory: factory)
      .increment(by: 2)
    Counter(label: "requests", dimensions: [("a", "other")], factory: factory)
      .increment(by: 10)
    clock.advance(by: 60)

    try await factory.export()

    let values = writer.writtenTimeSeries
      .map { ($0.metric.labels["a"] ?? "", $0.points[0].value.int64Value) }
      .sorted { $0.0 < $1.0 }
    #expect(values.map(\.0) == ["1", "other"])
    #expect(values.map(\.1) == [3, 10])
  }

  @Test func floatingPointCounterIsExportedAsCumulativeDouble() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    let counter = FloatingPointCounter(label: "bytes", factory: factory)
    counter.increment(by: 1.5)
    counter.increment(by: 2.25)
    clock.advance(by: 60)

    try await factory.export()

    let timeSeries = try #require(writer.writtenTimeSeries.first(type: "bytes"))
    #expect(timeSeries.metricKind == .cumulative)
    #expect(timeSeries.valueType == .double)
    #expect(timeSeries.points[0].value.doubleValue == 3.75)
  }

  @Test func meterIsExportedAsGauge() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    let meter = Meter(label: "connections", factory: factory)
    meter.set(10)
    meter.increment(by: 5)
    meter.decrement(by: 2)

    try await factory.export()

    let timeSeries = try #require(writer.writtenTimeSeries.first(type: "connections"))
    #expect(timeSeries.metricKind == .gauge)
    #expect(timeSeries.valueType == .double)
    #expect(timeSeries.points[0].value.doubleValue == 13)
    #expect(!timeSeries.points[0].interval.hasStartTime)
  }

  @Test func gaugeExportsLatestValue() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    let gauge = Gauge(label: "temperature", factory: factory)
    gauge.record(20)
    gauge.record(21.5)

    try await factory.export()

    let timeSeries = try #require(writer.writtenTimeSeries.first(type: "temperature"))
    #expect(timeSeries.metricKind == .gauge)
    #expect(timeSeries.points[0].value.doubleValue == 21.5)
  }

  @Test func gaugeWithoutValueIsSkipped() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    _ = Gauge(label: "temperature", factory: factory)
    _ = Meter(label: "connections", factory: factory)

    try await factory.export()

    #expect(writer.requests.isEmpty)
  }

  @Test func aggregatingRecorderIsExportedAsDistribution() async throws {
    let factory = makeFactory(
      writer: writer, clock: clock, recorderBuckets: .explicit(bounds: [10, 20]))

    let recorder = Recorder(label: "payload_size", factory: factory)
    for value in [5, 15, 15, 25] {
      recorder.record(value)
    }
    clock.advance(by: 60)

    try await factory.export()

    let timeSeries = try #require(writer.writtenTimeSeries.first(type: "payload_size"))
    #expect(timeSeries.metricKind == .cumulative)
    #expect(timeSeries.valueType == .distribution)
    let distribution = timeSeries.points[0].value.distributionValue
    #expect(distribution.count == 4)
    #expect(distribution.mean == 15)
    #expect(distribution.sumOfSquaredDeviation == 200)
    #expect(distribution.bucketCounts == [1, 2, 1])
    #expect(distribution.bucketOptions.explicitBuckets.bounds == [10, 20])
  }

  @Test func timerIsExportedAsDistributionInMilliseconds() async throws {
    let factory = makeFactory(
      writer: writer, clock: clock, timerBuckets: .linear(count: 2, width: 10, offset: 0))

    let timer = CoreMetrics.Timer(label: "latency", factory: factory)
    timer.recordMilliseconds(5)
    timer.recordNanoseconds(15_000_000)
    clock.advance(by: 60)

    try await factory.export()

    let timeSeries = try #require(writer.writtenTimeSeries.first(type: "latency"))
    #expect(timeSeries.unit == "ms")
    let distribution = timeSeries.points[0].value.distributionValue
    #expect(distribution.count == 2)
    #expect(distribution.mean == 10)
    #expect(distribution.bucketCounts == [0, 1, 1])
    #expect(distribution.bucketOptions.linearBuckets.numFiniteBuckets == 2)
  }

  @Test func distributionWithoutValuesIsSkipped() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    _ = CoreMetrics.Timer(label: "latency", factory: factory)
    clock.advance(by: 60)

    try await factory.export()

    #expect(writer.requests.isEmpty)
  }

  @Test func destroyedMetricIsExportedOnceMoreAndThenRemoved() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    let counter = Counter(label: "requests", factory: factory)
    counter.increment()
    let gauge = Gauge(label: "temperature", factory: factory)
    gauge.record(1)
    counter.destroy()
    clock.advance(by: 60)

    try await factory.export()
    #expect(writer.requests[0].timeSeries.first(type: "requests")?.points[0].value.int64Value == 1)

    clock.advance(by: 60)
    try await factory.export()
    #expect(
      writer.requests[1].timeSeries.map(\.metric.type) == ["custom.googleapis.com/temperature"])
  }

  @Test func destroyedMetricIsKeptWhileOtherHandlersExist() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    let first = Counter(label: "requests", factory: factory)
    let second = Counter(label: "requests", factory: factory)
    first.increment()
    first.destroy()
    clock.advance(by: 60)
    try await factory.export()

    second.increment()
    clock.advance(by: 60)
    try await factory.export()

    #expect(writer.writtenTimeSeries.map { $0.points[0].value.int64Value } == [1, 2])
  }

  @Test func metricRecreatedBeforeExportIsKept() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    Counter(label: "requests", factory: factory).destroy()
    let counter = Counter(label: "requests", factory: factory)
    counter.increment()
    clock.advance(by: 60)
    try await factory.export()
    clock.advance(by: 60)
    try await factory.export()

    #expect(writer.writtenTimeSeries.count == 2)
  }

  // MARK: - Collisions

  @Test func labelsSanitizedToSameIdentityShareHandler() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    Counter(label: "http-requests", dimensions: [("http.method", "GET")], factory: factory)
      .increment(by: 1)
    Counter(label: "http_requests", dimensions: [("http_method", "GET")], factory: factory)
      .increment(by: 2)
    clock.advance(by: 60)

    try await factory.export()

    #expect(writer.writtenTimeSeries.count == 1)
    #expect(writer.writtenTimeSeries.first?.points[0].value.int64Value == 3)
  }

  @Test func conflictingKindIsNotExported() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    Counter(label: "requests", factory: factory).increment(by: 1)
    FloatingPointCounter(label: "requests", factory: factory).increment(by: 2.5)
    Gauge(label: "requests", factory: factory).record(7)
    clock.advance(by: 60)

    try await factory.export()

    #expect(writer.writtenTimeSeries.count == 1)
    #expect(writer.writtenTimeSeries.first?.valueType == .int64)
    #expect(writer.writtenTimeSeries.first?.points[0].value.int64Value == 1)
  }

  @Test func meterAndGaugeWithSameLabelShareHandler() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    Gauge(label: "connections", factory: factory).record(3)
    Meter(label: "connections", factory: factory).increment(by: 2)

    try await factory.export()

    #expect(writer.writtenTimeSeries.count == 1)
    #expect(writer.writtenTimeSeries.first?.points[0].value.doubleValue == 5)
  }

  @Test func dimensionsAboveLabelLimitAreDropped() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    let dimensions = (0..<35).map { (String(format: "key%02d", $0), "value") }
    Gauge(label: "temperature", dimensions: dimensions, factory: factory).record(1)

    try await factory.export()

    let labels = try #require(writer.writtenTimeSeries.first?.metric.labels)
    #expect(labels.count == 30)
    #expect(labels["key00"] != nil)
    #expect(labels["key34"] == nil)
  }

  // MARK: - Value edge cases

  @Test func counterSaturatesInsteadOfOverflowing() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    let counter = Counter(label: "requests", factory: factory)
    counter.increment(by: Int64.max)
    counter.increment(by: 10)
    clock.advance(by: 60)

    try await factory.export()

    #expect(writer.writtenTimeSeries.first?.points[0].value.int64Value == .max)
  }

  @Test func floatingPointCounterSaturatesAtGreatestFiniteMagnitude() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    let counter = FloatingPointCounter(label: "bytes", factory: factory)
    counter.increment(by: Double.greatestFiniteMagnitude)
    counter.increment(by: Double.greatestFiniteMagnitude)
    clock.advance(by: 60)

    try await factory.export()

    #expect(writer.writtenTimeSeries.first?.points[0].value.doubleValue == .greatestFiniteMagnitude)
  }

  @Test func meterIgnoresNonPositiveAmounts() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    let meter = Meter(label: "connections", factory: factory)
    meter.set(10)
    meter.increment(by: -3)
    meter.increment(by: 0)
    meter.decrement(by: -3)
    meter.decrement(by: Double.nan)

    try await factory.export()

    #expect(writer.writtenTimeSeries.first?.points[0].value.doubleValue == 10)
  }

  @Test func resetAfterExportStartsAfterPreviousEndTime() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    let counter = Counter(label: "requests", factory: factory)
    counter.increment()
    clock.advance(by: 60)
    try await factory.export()
    let previousEndTime = clock.now

    counter.reset()
    clock.advance(by: 60)
    try await factory.export()

    let point = try #require(writer.requests.last?.timeSeries.first?.points.first)
    #expect(point.interval.startTime.date > previousEndTime)
  }

  @Test func distributionIgnoresValuesWhichWouldOverflow() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    let recorder = Recorder(label: "payload_size", factory: factory)
    recorder.record(1e300)
    recorder.record(-1e300)
    recorder.record(4)
    clock.advance(by: 60)

    try await factory.export()

    let distribution = try #require(writer.writtenTimeSeries.first?.points[0].value.distributionValue)
    #expect(distribution.count == 1)
    #expect(distribution.mean == 4)
    #expect(distribution.sumOfSquaredDeviation.isFinite)
  }

  @Test func timerIgnoresNegativeDurations() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    let timer = CoreMetrics.Timer(label: "latency", factory: factory)
    timer.recordNanoseconds(-1_000_000)
    timer.recordMilliseconds(2)
    clock.advance(by: 60)

    try await factory.export()

    let distribution = try #require(writer.writtenTimeSeries.first?.points[0].value.distributionValue)
    #expect(distribution.count == 1)
    #expect(distribution.mean == 2)
  }

  // MARK: - Resource

  @Test func defaultTaskIDIncludesProcessID() {
    let taskID = GoogleCloudMetricsFactory.defaultTaskID(
      instanceID: "instance", fallbackTaskID: "fallback", environment: [:], hostName: "host",
      processID: 42)
    #expect(taskID == "instance-42")
  }

  @Test func defaultTaskIDUsesFallbackWithoutInstanceID() {
    let taskID = GoogleCloudMetricsFactory.defaultTaskID(
      instanceID: nil, fallbackTaskID: "fallback", environment: [:], hostName: "host",
      processID: 42)
    #expect(taskID == "fallback-42")
  }

  @Test func defaultTaskIDUsesPodOnKubernetes() {
    let withPodName = GoogleCloudMetricsFactory.defaultTaskID(
      instanceID: "node", fallbackTaskID: "fallback",
      environment: ["KUBERNETES_SERVICE_HOST": "10.0.0.1", "KUBERNETES_POD_NAME": "api-abc"],
      hostName: "host", processID: 1)
    #expect(withPodName == "api-abc-1")

    let withoutPodName = GoogleCloudMetricsFactory.defaultTaskID(
      instanceID: "node", fallbackTaskID: "fallback",
      environment: ["KUBERNETES_SERVICE_HOST": "10.0.0.1"],
      hostName: "api-def", processID: 1)
    #expect(withoutPodName == "api-def-1")
  }

  @Test func exportIsSplitIntoRequestsOfAtMost200TimeSeries() async throws {
    let factory = makeFactory(writer: writer, clock: clock)

    for index in 0..<450 {
      Gauge(label: "gauge", dimensions: [("index", "\(index)")], factory: factory).record(1)
    }

    try await factory.export()

    #expect(writer.requests.map(\.timeSeries.count) == [200, 200, 50])
  }

  @Test func exportWritesAllBatchesAndThrowsFirstError() async throws {
    struct WriteError: Error {}

    let factory = makeFactory(writer: writer, clock: clock)
    for index in 0..<250 {
      Gauge(label: "gauge", dimensions: [("index", "\(index)")], factory: factory).record(1)
    }
    writer.fail(with: WriteError())

    await #expect(throws: WriteError.self) {
      try await factory.export()
    }
    #expect(writer.requests.count == 2)
  }
}
