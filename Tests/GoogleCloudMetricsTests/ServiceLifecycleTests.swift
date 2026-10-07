import CoreMetrics
import Logging
import ServiceLifecycle
import Testing

@testable import GoogleCloudMetrics

@Suite struct ServiceLifecycleTests {

  @Test func gracefulShutdownExportsRemainingMetrics() async throws {
    let writer = FakeTimeSeriesWriter()
    let clock = TestClock()
    let factory = makeFactory(writer: writer, clock: clock, exportInterval: .seconds(3600))

    let serviceGroup = ServiceGroup(
      configuration: ServiceGroupConfiguration(
        services: [
          .init(service: factory),
          .init(
            service: RecordingService(factory: factory, clock: clock),
            successTerminationBehavior: .gracefullyShutdownGroup
          ),
        ],
        logger: Logger(label: "test")
      ))

    try await serviceGroup.run()

    #expect(writer.writtenTimeSeries.first(type: "requests")?.points.first?.value.int64Value == 3)
  }

  @Test func exportsPeriodically() async throws {
    let writer = FakeTimeSeriesWriter()
    let factory = makeFactory(writer: writer, exportInterval: .milliseconds(10))

    Gauge(label: "temperature", factory: factory).record(1)

    let serviceGroup = ServiceGroup(
      configuration: ServiceGroupConfiguration(
        services: [
          .init(service: factory),
          .init(
            service: WaitingService { writer.requests.count >= 2 },
            successTerminationBehavior: .gracefullyShutdownGroup
          ),
        ],
        logger: Logger(label: "test")
      ))

    try await serviceGroup.run()

    #expect(writer.requests.count >= 3)
  }

  @Test func writerFailureStopsExporting() async throws {
    struct TransportError: Error {}

    let writer = FakeTimeSeriesWriter()
    let factory = makeFactory(writer: writer, exportInterval: .seconds(3600))

    let run = Task { try await factory.run() }
    writer.failRun(with: TransportError())

    await #expect(throws: TransportError.self) {
      try await run.value
    }
  }

  @Test func runningTwiceThrows() async throws {
    let writer = FakeTimeSeriesWriter()
    let factory = makeFactory(writer: writer)

    let serviceGroup = ServiceGroup(
      configuration: ServiceGroupConfiguration(
        services: [
          .init(service: factory),
          .init(
            service: WaitingService { true },
            successTerminationBehavior: .gracefullyShutdownGroup
          ),
        ],
        logger: Logger(label: "test")
      ))
    try await serviceGroup.run()

    await #expect(throws: GoogleCloudMetricsFactory.ExportError.self) {
      try await factory.run()
    }
  }

  @Test func finalExportIsBoundedByShutdownTimeout() async throws {
    let writer = FakeTimeSeriesWriter()
    writer.delayWrites(by: .seconds(3600))
    let factory = makeFactory(
      writer: writer, exportInterval: .seconds(3600), shutdownTimeout: .milliseconds(50))
    Gauge(label: "temperature", factory: factory).record(1)

    let serviceGroup = ServiceGroup(
      configuration: ServiceGroupConfiguration(
        services: [
          .init(service: factory),
          .init(
            service: WaitingService { true },
            successTerminationBehavior: .gracefullyShutdownGroup
          ),
        ],
        logger: Logger(label: "test")
      ))

    let start = ContinuousClock.now
    try await serviceGroup.run()

    #expect(ContinuousClock.now - start < .seconds(5))
    #expect(writer.requests.isEmpty)
  }

  struct RecordingService: Service {

    let factory: GoogleCloudMetricsFactory
    let clock: TestClock

    func run() async throws {
      Counter(label: "requests", factory: factory).increment(by: 3)
      clock.advance(by: 1)
    }
  }

  struct WaitingService: Service {

    let condition: @Sendable () -> Bool

    func run() async throws {
      while !condition() {
        try await Task.sleep(for: .milliseconds(5))
      }
    }
  }
}
