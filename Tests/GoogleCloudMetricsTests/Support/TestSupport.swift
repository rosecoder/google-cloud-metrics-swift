import Foundation
import Synchronization

@testable import GoogleCloudMetrics

final class TestClock: Sendable {

  private let current: Mutex<Date>

  init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
    self.current = Mutex(start)
  }

  var now: Date {
    current.withLock { $0 }
  }

  func advance(by interval: TimeInterval) {
    current.withLock { $0 += interval }
  }
}

final class FakeTimeSeriesWriter: TimeSeriesWriter {

  struct Request: Sendable {
    let projectID: String
    let timeSeries: [Google_Monitoring_V3_TimeSeries]
  }

  struct WriteAfterShutdownError: Error {}

  private struct State {
    var requests: [Request] = []
    var writeError: (any Error)?
    var writeDelay: Duration?
    var runError: (any Error)?
    var isShutDown = false
  }

  private let state = Mutex(State())
  private let shutdownStream: AsyncStream<Void>
  private let shutdownContinuation: AsyncStream<Void>.Continuation

  init() {
    (shutdownStream, shutdownContinuation) = AsyncStream<Void>.makeStream()
  }

  var requests: [Request] {
    state.withLock { $0.requests }
  }

  var writtenTimeSeries: [Google_Monitoring_V3_TimeSeries] {
    requests.flatMap(\.timeSeries)
  }

  func fail(with error: (any Error)?) {
    state.withLock { $0.writeError = error }
  }

  /// Makes every write wait for `delay` (or until cancelled) before being recorded.
  func delayWrites(by delay: Duration?) {
    state.withLock { $0.writeDelay = delay }
  }

  /// Makes `run()` throw `error`, like a transport failing.
  func failRun(with error: any Error) {
    state.withLock { $0.runError = error }
    shutdownContinuation.finish()
  }

  func run() async throws {
    for await _ in shutdownStream {}
    if let error = state.withLock({ $0.runError }) {
      throw error
    }
  }

  func beginGracefulShutdown() {
    state.withLock { $0.isShutDown = true }
    shutdownContinuation.finish()
  }

  func write(_ timeSeries: [Google_Monitoring_V3_TimeSeries], projectID: String) async throws {
    if let delay = state.withLock({ $0.writeDelay }) {
      try await Task.sleep(for: delay)
    }
    let error: (any Error)? = state.withLock { state in
      if state.isShutDown {
        return WriteAfterShutdownError()
      }
      state.requests.append(Request(projectID: projectID, timeSeries: timeSeries))
      return state.writeError
    }
    if let error {
      throw error
    }
  }
}

let testResource = MonitoredResource.genericTask(
  projectID: "test-project",
  location: "europe-west1",
  namespace: "default",
  job: "test-job",
  taskID: "test-task"
)

func makeFactory(
  writer: FakeTimeSeriesWriter = FakeTimeSeriesWriter(),
  clock: TestClock = TestClock(),
  exportInterval: Duration = .seconds(60),
  shutdownTimeout: Duration = .seconds(8),
  timerBuckets: DistributionBuckets = .defaultTimer,
  recorderBuckets: DistributionBuckets = .defaultRecorder
) -> GoogleCloudMetricsFactory {
  GoogleCloudMetricsFactory(
    projectID: "test-project",
    resource: testResource,
    metricTypePrefix: "custom.googleapis.com/",
    exportInterval: exportInterval,
    shutdownTimeout: shutdownTimeout,
    timerBuckets: timerBuckets,
    recorderBuckets: recorderBuckets,
    writer: writer,
    minimumExportInterval: .zero,
    now: { clock.now }
  )
}

extension Array where Element == Google_Monitoring_V3_TimeSeries {

  func first(type: String) -> Google_Monitoring_V3_TimeSeries? {
    first { $0.metric.type == "custom.googleapis.com/" + type }
  }
}
