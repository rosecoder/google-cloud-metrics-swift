import CoreMetrics
import Foundation
import GoogleCloudAuth
import GoogleCloudAuthTesting
import GoogleCloudServiceContext
import Logging
import ServiceLifecycle
import SwiftProtobuf
import Testing

@testable import GoogleCloudMetrics

// Serialized since shutting down a connection also shuts down the shared authorization provider.
@Suite(.enabledIfAuthenticatedWithGoogleCloud, .serialized)
struct IntegrationTests {

  let runID = UUID().uuidString.lowercased()

  @Test func writeAllMetricKinds() async throws {
    let factory = try GoogleCloudMetricsFactory()
    let dimensions = [("run_id", runID)]

    Counter(label: "swift_integration_test/counter", dimensions: dimensions, factory: factory)
      .increment(by: 3)
    FloatingPointCounter(
      label: "swift_integration_test/floating_point_counter", dimensions: dimensions,
      factory: factory
    ).increment(by: 1.5)
    Meter(label: "swift_integration_test/meter", dimensions: dimensions, factory: factory)
      .set(7)
    Gauge(label: "swift_integration_test/gauge", dimensions: dimensions, factory: factory)
      .record(42)
    let recorder = Recorder(
      label: "swift_integration_test/recorder", dimensions: dimensions, factory: factory)
    [1, 10, 100].forEach { recorder.record($0) }
    let timer = CoreMetrics.Timer(
      label: "swift_integration_test/timer", dimensions: dimensions, factory: factory)
    timer.recordMilliseconds(5)
    timer.recordMilliseconds(15)

    try await Task.sleep(for: .milliseconds(100))

    try await withRunningConnection(factory.writer) {
      try await factory.export()
    }

    try await withMetricReader { reader in
      let counter = try await reader.waitForTimeSeries(
        type: "swift_integration_test/counter", runID: runID)
      #expect(counter.metricKind == .cumulative)
      #expect(counter.points.first?.value.int64Value == 3)

      let floatingPointCounter = try await reader.waitForTimeSeries(
        type: "swift_integration_test/floating_point_counter", runID: runID)
      #expect(floatingPointCounter.points.first?.value.doubleValue == 1.5)

      let meter = try await reader.waitForTimeSeries(
        type: "swift_integration_test/meter", runID: runID)
      #expect(meter.metricKind == .gauge)
      #expect(meter.points.first?.value.doubleValue == 7)

      let gauge = try await reader.waitForTimeSeries(
        type: "swift_integration_test/gauge", runID: runID)
      #expect(gauge.points.first?.value.doubleValue == 42)

      let recorderSeries = try await reader.waitForTimeSeries(
        type: "swift_integration_test/recorder", runID: runID)
      #expect(recorderSeries.points.first?.value.distributionValue.count == 3)
      #expect(recorderSeries.points.first?.value.distributionValue.mean == 37)

      let timerSeries = try await reader.waitForTimeSeries(
        type: "swift_integration_test/timer", runID: runID)
      #expect(timerSeries.points.first?.value.distributionValue.count == 2)
      #expect(timerSeries.points.first?.value.distributionValue.mean == 10)
    }
  }

  @Test func expiredCounterIsRecreatedAfterPreviousPoint() async throws {
    let factory = try GoogleCloudMetricsFactory(idleExpiration: IdleExpiration(after: .zero))
    let label = "swift_integration_test/expiring_counter"
    let dimensions = [("run_id", runID)]

    try await withRunningConnection(factory.writer) {
      Counter(label: label, dimensions: dimensions, factory: factory).increment(by: 2)
      try await Task.sleep(for: .milliseconds(100))
      try await factory.export()

      Counter(label: label, dimensions: dimensions, factory: factory).increment(by: 3)
      try await Task.sleep(for: GoogleCloudMetricsFactory.minimumExportInterval + .seconds(1))
      try await factory.export()
    }

    try await withMetricReader { reader in
      let counter = try await reader.waitForTimeSeries(
        type: label, runID: runID, minimumPointCount: 2)
      #expect(counter.points.map(\.value.int64Value) == [3, 2])
      #expect(counter.points[0].interval.startTime.date > counter.points[1].interval.endTime.date)
    }
  }

  @Test func exportOnGracefulShutdown() async throws {
    var logger = Logger(label: "test")
    logger.logLevel = .trace

    var context = ServiceContext.current ?? .topLevel
    context.serviceName = "test-api"

    try await ServiceContext.withValue(context) {
      let factory = try GoogleCloudMetricsFactory()

      let serviceGroup = ServiceGroup(
        configuration: ServiceGroupConfiguration(
          services: [
            .init(service: factory),
            .init(
              service: AppService(factory: factory, runID: runID),
              successTerminationBehavior: .gracefullyShutdownGroup
            ),
          ],
          logger: logger
        ))

      try await serviceGroup.run()
    }

    try await withMetricReader { reader in
      let counter = try await reader.waitForTimeSeries(
        type: "swift_integration_test/lifecycle_counter", runID: runID)
      #expect(counter.points.first?.value.int64Value == 5)
      #expect(counter.resource.type == "generic_task")
      #expect(counter.resource.labels["job"] == "test-api")
    }
  }

  struct AppService: Service {

    let factory: GoogleCloudMetricsFactory
    let runID: String

    func run() async throws {
      Counter(
        label: "swift_integration_test/lifecycle_counter",
        dimensions: [("run_id", runID)],
        factory: factory
      ).increment(by: 5)
      try await Task.sleep(for: .milliseconds(100))
    }
  }
}

private func withRunningConnection<Result: Sendable>(
  _ connection: any TimeSeriesWriter,
  operation: () async throws -> Result
) async throws -> Result {
  async let run: Void = connection.run()
  let result: Swift.Result<Result, any Error>
  do {
    result = .success(try await operation())
  } catch {
    result = .failure(error)
  }
  connection.beginGracefulShutdown()
  try await run
  return try result.get()
}

private func withMetricReader(_ operation: (MetricReader) async throws -> Void) async throws {
  let projectID = try #require(await (ServiceContext.current ?? .topLevel).projectID)
  let connection = try MetricServiceConnection(
    scopes: ["https://www.googleapis.com/auth/monitoring.read"],
    authorizationProvider: DefaultProvider.shared
  )
  try await withRunningConnection(connection) {
    try await operation(MetricReader(connection: connection, projectID: projectID))
  }
}

private struct MetricReader {

  let connection: MetricServiceConnection
  let projectID: String

  struct TimeoutError: Error, CustomStringConvertible {
    let type: String
    var description: String { "Timed out waiting for time series of type \(type)" }
  }

  /// Newly written points may take a while before they can be read, so this polls until found.
  func waitForTimeSeries(
    type: String,
    runID: String,
    minimumPointCount: Int = 1,
    timeout: Duration = .seconds(180)
  ) async throws -> Google_Monitoring_V3_TimeSeries {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if let timeSeries = try await listTimeSeries(type: type, runID: runID)
        .first(where: { $0.points.count >= minimumPointCount })
      {
        return timeSeries
      }
      try await Task.sleep(for: .seconds(5))
    }
    throw TimeoutError(type: type)
  }

  private func listTimeSeries(type: String, runID: String) async throws
    -> [Google_Monitoring_V3_TimeSeries]
  {
    let now = Date()
    let response = try await connection.client.listTimeSeries(
      .with {
        $0.name = "projects/" + projectID
        $0.filter =
          "metric.type = \"custom.googleapis.com/\(type)\" AND metric.labels.run_id = \"\(runID)\""
        $0.interval = .with {
          $0.startTime = Google_Protobuf_Timestamp(date: now.addingTimeInterval(-15 * 60))
          $0.endTime = Google_Protobuf_Timestamp(date: now.addingTimeInterval(60))
        }
        $0.view = .full
      })
    return response.timeSeries
  }
}
