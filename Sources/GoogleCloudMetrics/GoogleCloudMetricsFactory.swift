import CoreMetrics
import Foundation
import GoogleCloudAuth
import GoogleCloudServiceContext
import Logging
import ServiceLifecycle
import Synchronization

/// A `MetricsFactory` which periodically exports all metrics to Google Cloud Monitoring.
///
/// The factory must be bootstrapped with `MetricsSystem.bootstrap(_:)` and run as a service
/// (for example in a `ServiceGroup`) for metrics to be exported.
public final class GoogleCloudMetricsFactory: MetricsFactory, Service {

  let logger = Logger(label: "metrics.write")

  /// Cloud Monitoring only accepts one point per time series every 5 seconds.
  static let minimumExportInterval: Duration = .seconds(5)

  /// Cloud Monitoring accepts at most 200 time series per `CreateTimeSeries` request.
  static let maximumTimeSeriesPerRequest = 200

  public let exportInterval: Duration
  public let shutdownTimeout: Duration
  public let metricTypePrefix: String
  public let timerBuckets: DistributionBuckets
  public let recorderBuckets: DistributionBuckets

  let projectID: String?
  let resource: MonitoredResource?
  let writer: any TimeSeriesWriter
  let registry: MetricsRegistry
  let now: @Sendable () -> Date
  let minimumExportInterval: Duration

  private let fallbackTaskID = UUID().uuidString.lowercased()
  private let hasStarted = Mutex(false)
  private let resolvedTarget = Mutex<ExportTarget?>(nil)
  private let lastExportInstant = Mutex<ContinuousClock.Instant?>(nil)

  /// Creates a new factory which exports metrics to Cloud Monitoring.
  ///
  /// - Parameters:
  ///   - projectID: Project to write metrics to. Resolved from the current `ServiceContext` if `nil`.
  ///   - resource: Monitored resource to attach to all time series. Defaults to a `generic_task`
  ///     resource populated from the current `ServiceContext`.
  ///   - metricTypePrefix: Prefix for all metric types. Metric labels are appended to this prefix.
  ///   - exportInterval: Interval between exports. Must be at least 5 seconds.
  ///   - shutdownTimeout: Maximum time spent writing remaining metrics on graceful shutdown,
  ///     including waiting for the 5 second minimum interval between points. Defaults to 8
  ///     seconds, which fits within the 10 seconds Cloud Run waits after sending `SIGTERM`.
  ///   - timerBuckets: Buckets used for timers. Timers are exported in milliseconds.
  ///   - recorderBuckets: Buckets used for aggregating recorders.
  ///   - authorizationProvider: Provider used to authorize requests to Cloud Monitoring.
  public convenience init(
    projectID: String? = nil,
    resource: MonitoredResource? = nil,
    metricTypePrefix: String = "custom.googleapis.com/",
    exportInterval: Duration = .seconds(60),
    shutdownTimeout: Duration = .seconds(8),
    timerBuckets: DistributionBuckets = .defaultTimer,
    recorderBuckets: DistributionBuckets = .defaultRecorder,
    authorizationProvider: GoogleCloudAuth.Provider = DefaultProvider.shared
  ) throws {
    precondition(
      exportInterval >= Self.minimumExportInterval,
      "Export interval must be at least \(Self.minimumExportInterval).")

    self.init(
      projectID: projectID,
      resource: resource,
      metricTypePrefix: metricTypePrefix,
      exportInterval: exportInterval,
      shutdownTimeout: shutdownTimeout,
      timerBuckets: timerBuckets,
      recorderBuckets: recorderBuckets,
      writer: try MetricServiceConnection(
        scopes: ["https://www.googleapis.com/auth/monitoring.write"],
        authorizationProvider: authorizationProvider
      ),
      minimumExportInterval: Self.minimumExportInterval,
      now: { Date() }
    )
  }

  init(
    projectID: String?,
    resource: MonitoredResource?,
    metricTypePrefix: String,
    exportInterval: Duration,
    shutdownTimeout: Duration,
    timerBuckets: DistributionBuckets,
    recorderBuckets: DistributionBuckets,
    writer: any TimeSeriesWriter,
    minimumExportInterval: Duration,
    now: @escaping @Sendable () -> Date
  ) {
    self.projectID = projectID
    self.resource = resource
    self.metricTypePrefix = metricTypePrefix
    self.exportInterval = exportInterval
    self.shutdownTimeout = shutdownTimeout
    self.timerBuckets = timerBuckets
    self.recorderBuckets = recorderBuckets
    self.writer = writer
    self.registry = MetricsRegistry(logger: logger)
    self.minimumExportInterval = minimumExportInterval
    self.now = now
  }

  // MARK: - Service

  public func run() async throws {
    let wasStarted = hasStarted.withLock { hasStarted in
      defer { hasStarted = true }
      return hasStarted
    }
    guard !wasStarted else {
      throw ExportError.alreadyRunning
    }

    // If the writer fails, the group cancels the exports instead of exporting to a dead writer.
    try await withThrowingDiscardingTaskGroup { group in
      group.addTask(priority: .background) {
        try await self.writer.run()
      }
      group.addTask {
        await self.runExports()
        self.writer.beginGracefulShutdown()
      }
    }
  }

  private func runExports() async {
    do {
      _ = try await resolveTarget()
    } catch {
      logger.warning("\(error) Resolving will be retried on every export.")
    }
    await runExportLoop()
    await exportFinal()
  }

  private func runExportLoop() async {
    while true {
      do {
        try await cancelWhenGracefulShutdown {
          try await Task.sleep(for: self.exportInterval)
        }
      } catch {
        return
      }
      await exportAndLog(timeout: exportInterval)
    }
  }

  private func exportFinal() async {
    guard !Task.isCancelled else {
      return
    }
    let deadline = ContinuousClock.now.advanced(by: shutdownTimeout)
    if let lastExportInstant = lastExportInstant.withLock({ $0 }) {
      let nextAllowedInstant = lastExportInstant.advanced(by: minimumExportInterval)
      if nextAllowedInstant > .now, nextAllowedInstant < deadline {
        try? await Task.sleep(until: nextAllowedInstant)
      }
    }
    await exportAndLog(timeout: deadline - ContinuousClock.now)
  }

  /// Exports, giving up after `timeout` so a slow or unreachable API can't stall the loop or
  /// shutdown.
  private func exportAndLog(timeout: Duration) async {
    let didComplete = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await self.exportAndLog()
        return true
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return false
      }
      let didComplete = await group.next() ?? false
      group.cancelAll()
      return didComplete
    }
    if !didComplete {
      logger.error("Timed out writing metrics after \(timeout).")
    }
  }

  private func exportAndLog() async {
    do {
      try await export()
    } catch {
      logger.error("Error writing metrics: \(error)")
    }
  }

  // MARK: - Export

  struct ExportTarget: Sendable {
    let projectID: String
    let resource: MonitoredResource
  }

  enum ExportError: Error, CustomStringConvertible {
    case missingProjectID
    case alreadyRunning

    var description: String {
      switch self {
      case .missingProjectID:
        return """
          Unable to resolve the Google Cloud project to write metrics to. Pass `projectID` to \
          GoogleCloudMetricsFactory, set the GOOGLE_CLOUD_PROJECT environment variable or, when \
          running on Google Cloud, create a GoogleServiceContextResolver and run it in the same \
          ServiceGroup.
          """
      case .alreadyRunning:
        return "GoogleCloudMetricsFactory.run() must only be called once."
      }
    }
  }

  /// Collects the current value of all metrics and writes them to Cloud Monitoring.
  func export() async throws {
    let target = try await resolveTarget()
    let endTime = now()
    let timeSeries = registry.collect(endingAt: endTime).map {
      TimeSeriesEncoder.encode($0, endTime: endTime, resource: target.resource)
    }
    guard !timeSeries.isEmpty else {
      return
    }
    lastExportInstant.withLock { $0 = .now }

    logger.trace("Writing \(timeSeries.count) time series...")

    var firstError: (any Error)?
    for start in stride(from: 0, to: timeSeries.count, by: Self.maximumTimeSeriesPerRequest) {
      let end = min(start + Self.maximumTimeSeriesPerRequest, timeSeries.count)
      do {
        try await writer.write(Array(timeSeries[start..<end]), projectID: target.projectID)
      } catch {
        firstError = firstError ?? error
      }
    }
    if let firstError {
      throw firstError
    }
    logger.debug("Successfully wrote \(timeSeries.count) time series.")
  }

  private func resolveTarget() async throws -> ExportTarget {
    if let target = resolvedTarget.withLock({ $0 }) {
      return target
    }
    let context = ServiceContext.current ?? .topLevel
    let resolvedProjectID: String?
    if let projectID {
      resolvedProjectID = projectID
    } else {
      resolvedProjectID = await context.projectID
    }
    guard let projectID = resolvedProjectID else {
      throw ExportError.missingProjectID
    }
    let resource: MonitoredResource
    if let explicitResource = self.resource {
      resource = explicitResource
    } else {
      resource = .genericTask(
        projectID: projectID,
        location: await context.locationID ?? "global",
        namespace: "default",
        job: context.serviceName ?? ProcessInfo.processInfo.processName,
        taskID: Self.defaultTaskID(
          instanceID: await context.instanceID,
          fallbackTaskID: fallbackTaskID
        )
      )
    }
    let target = ExportTarget(projectID: projectID, resource: resource)
    resolvedTarget.withLock { $0 = target }
    return target
  }

  /// Creates a task ID which is unique per process, since Cloud Monitoring rejects points
  /// written to the same time series from multiple processes.
  ///
  /// On Kubernetes, the instance ID resolves to the node unless `KUBERNETES_POD_NAME` is set, so
  /// the pod's hostname is used instead.
  static func defaultTaskID(
    instanceID: String?,
    fallbackTaskID: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    hostName: @autoclosure () -> String = ProcessInfo.processInfo.hostName,
    processID: Int32 = ProcessInfo.processInfo.processIdentifier
  ) -> String {
    let base: String
    if let podName = environment["KUBERNETES_POD_NAME"] {
      base = podName
    } else if environment["KUBERNETES_SERVICE_HOST"] != nil {
      base = hostName()
    } else {
      base = instanceID ?? fallbackTaskID
    }
    return "\(base)-\(processID)"
  }

  // MARK: - MetricsFactory

  public func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
    registry.metric(for: key(.counter, label: label, dimensions: dimensions)) {
      CounterMetric(key: $0, startTime: now(), now: now)
    }
  }

  public func makeFloatingPointCounter(label: String, dimensions: [(String, String)])
    -> FloatingPointCounterHandler
  {
    registry.metric(for: key(.floatingPointCounter, label: label, dimensions: dimensions)) {
      FloatingPointCounterMetric(key: $0, startTime: now(), now: now)
    }
  }

  public func makeMeter(label: String, dimensions: [(String, String)]) -> MeterHandler {
    registry.metric(for: key(.gauge, label: label, dimensions: dimensions)) {
      GaugeMetric(key: $0)
    }
  }

  public func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool)
    -> RecorderHandler
  {
    if aggregate {
      return registry.metric(for: key(.recorder, label: label, dimensions: dimensions)) {
        DistributionMetric(key: $0, buckets: recorderBuckets, startTime: now())
      }
    }
    return registry.metric(for: key(.gauge, label: label, dimensions: dimensions)) {
      GaugeMetric(key: $0)
    }
  }

  public func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
    registry.metric(for: key(.timer, label: label, dimensions: dimensions)) {
      DistributionMetric(key: $0, buckets: timerBuckets, startTime: now())
    }
  }

  private func key(_ kind: MetricKey.Kind, label: String, dimensions: [(String, String)])
    -> MetricKey
  {
    MetricKey(kind: kind, label: label, dimensions: dimensions, metricTypePrefix: metricTypePrefix)
  }

  public func destroyCounter(_ handler: CounterHandler) {
    registry.release(handler as? any ExportableMetric)
  }

  public func destroyFloatingPointCounter(_ handler: FloatingPointCounterHandler) {
    registry.release(handler as? any ExportableMetric)
  }

  public func destroyMeter(_ handler: MeterHandler) {
    registry.release(handler as? any ExportableMetric)
  }

  public func destroyRecorder(_ handler: RecorderHandler) {
    registry.release(handler as? any ExportableMetric)
  }

  public func destroyTimer(_ handler: TimerHandler) {
    registry.release(handler as? any ExportableMetric)
  }
}
