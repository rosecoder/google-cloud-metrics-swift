import Foundation
import Logging
import Synchronization

/// Identifies an exported time series (excluding the monitored resource).
///
/// Labels and dimensions are sanitized when the key is created, so different labels or
/// dimensions which map to the same metric type and metric labels share the same key.
struct MetricKey: Equatable, Sendable {

  enum Kind: Hashable, Sendable {
    case counter
    case floatingPointCounter
    /// Meters and non-aggregating recorders.
    case gauge
    case recorder
    case timer
  }

  struct Identity: Hashable, Sendable {
    let metricType: String
    let labels: [String: String]
  }

  /// Cloud Monitoring accepts at most 30 labels per metric.
  static let maximumLabelCount = 30

  let kind: Kind
  let identity: Identity
  /// Number of dimensions dropped because of the label limit.
  let droppedLabelCount: Int

  var metricType: String { identity.metricType }
  var labels: [String: String] { identity.labels }

  init(kind: Kind, label: String, dimensions: [(String, String)], metricTypePrefix: String) {
    var labels = [String: String](minimumCapacity: dimensions.count)
    for (key, value) in dimensions.sorted(by: { $0.0 < $1.0 }) {
      labels[Self.labelKey(key)] = Self.labelValue(value)
    }
    let droppedLabelCount = max(0, labels.count - Self.maximumLabelCount)
    if droppedLabelCount > 0 {
      for key in labels.keys.sorted().suffix(droppedLabelCount) {
        labels[key] = nil
      }
    }
    self.kind = kind
    self.identity = Identity(
      metricType: Self.metricType(label: label, prefix: metricTypePrefix),
      labels: labels
    )
    self.droppedLabelCount = droppedLabelCount
  }

  // MARK: - Names

  static let maximumLabelKeyLength = 100
  static let maximumLabelValueUTF8Length = 1024

  /// Creates a metric type from a label. Characters not allowed in metric types are replaced
  /// with underscores and empty path segments are removed.
  static func metricType(label: String, prefix: String) -> String {
    let sanitized = String(
      String.UnicodeScalarView(
        label.unicodeScalars.map { scalar in
          isAllowedInMetricType(scalar) ? scalar : "_"
        }
      ))
    let path = sanitized.split(separator: "/", omittingEmptySubsequences: true)
      .joined(separator: "/")
    return prefix + (path.isEmpty ? "unnamed" : path)
  }

  private static func isAllowedInMetricType(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "a"..."z", "A"..."Z", "0"..."9", "_", "/", ".":
      return true
    default:
      return false
    }
  }

  /// Creates a label key matching `[a-zA-Z][a-zA-Z0-9_]*` with at most 100 characters.
  static func labelKey(_ key: String) -> String {
    var scalars = String.UnicodeScalarView(
      key.unicodeScalars.map { scalar in
        isAllowedInLabelKey(scalar) ? scalar : "_"
      }
    )
    if let first = scalars.first, !isLetter(first) {
      scalars.insert(contentsOf: "key_".unicodeScalars, at: scalars.startIndex)
    } else if scalars.isEmpty {
      scalars.append(contentsOf: "key".unicodeScalars)
    }
    return String(String(scalars).prefix(maximumLabelKeyLength))
  }

  private static func isAllowedInLabelKey(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "a"..."z", "A"..."Z", "0"..."9", "_":
      return true
    default:
      return false
    }
  }

  private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "a"..."z", "A"..."Z":
      return true
    default:
      return false
    }
  }

  static func labelValue(_ value: String) -> String {
    guard value.utf8.count > maximumLabelValueUTF8Length else {
      return value
    }
    var truncated = ""
    var length = 0
    for character in value {
      length += character.utf8.count
      if length > maximumLabelValueUTF8Length {
        break
      }
      truncated.append(character)
    }
    return truncated
  }
}

enum MetricPoint: Equatable, Sendable {
  case counter(startTime: Date, value: Int64)
  case floatingPointCounter(startTime: Date, value: Double)
  case gauge(Double)
  case distribution(startTime: Date, DistributionSnapshot)
}

struct MetricSnapshot: Equatable, Sendable {
  let key: MetricKey
  let point: MetricPoint
}

protocol ExportableMetric: AnyObject, Sendable {

  var key: MetricKey { get }

  /// Incremented on every accepted update, so idle metrics are detected without reading the
  /// clock on every update.
  var updateCount: UInt64 { get }

  /// Returns the point to export, or `nil` if there is nothing to export.
  func point(endingAt endTime: Date) -> MetricPoint?
}

/// Cloud Monitoring rejects cumulative points where the start time is not before the end time.
let minimumCumulativeInterval: TimeInterval = 0.001

final class MetricsRegistry: Sendable {

  private struct Entry {
    let metric: any ExportableMetric
    /// Number of handles which are neither destroyed nor deallocated.
    var liveHandles = 1
    /// Number of handles which are not destroyed. Entries where every handle is destroyed are
    /// removed after their final value has been collected, regardless of idle expiration.
    var undestroyedHandles = 1
    var observedUpdateCount: UInt64 = 0
    /// End time of the first collect which observed the latest update.
    var lastActivity: Date?
  }

  private struct State {
    var entries: [MetricKey.Identity: Entry] = [:]
    var reportedConflicts: Set<MetricKey.Identity> = []
    /// End time of the last point written for removed metrics, so a re-created metric starts
    /// after it.
    var lastEndTimes: [MetricKey.Identity: Date] = [:]
  }

  private let logger: Logger
  private let idleExpiration: IdleExpiration?
  private let idleExpirationInterval: TimeInterval
  private let lastEndTimeRetention: TimeInterval
  private let state = Mutex(State())

  init(logger: Logger, idleExpiration: IdleExpiration?, exportInterval: Duration) {
    self.logger = logger
    self.idleExpiration = idleExpiration
    let idleExpirationAfter = idleExpiration?.after ?? .zero
    self.idleExpirationInterval = idleExpirationAfter.timeInterval
    self.lastEndTimeRetention = (max(idleExpirationAfter, exportInterval) + .seconds(3600))
      .timeInterval
  }

  var lastEndTimeCount: Int {
    state.withLock { $0.lastEndTimes.count }
  }

  /// Returns the existing metric for the key, or stores and returns a newly created one, and
  /// leases it until `release(_:destroy:)` is called.
  ///
  /// The same metric is returned for the same label and dimensions, so values are aggregated
  /// across all `Counter`, `Timer`, etc. instances using the same identity. `create` is passed
  /// the end time of the last point written for a removed metric with the same identity.
  ///
  /// If a metric of another kind is already registered for the same identity, a new metric
  /// which is never exported and isn't leased is returned, since Cloud Monitoring doesn't allow
  /// mixing kinds within a metric type.
  func acquire<Metric: ExportableMetric>(
    _ key: MetricKey,
    create: (MetricKey, _ lastEndTime: Date?) -> Metric
  ) -> (metric: Metric, isLeased: Bool) {
    let result:
      (metric: Metric, isNew: Bool, isLeased: Bool, conflictingKind: MetricKey.Kind?) =
        state.withLock { state in
          guard let existing = state.entries[key.identity] else {
            let metric = create(key, state.lastEndTimes[key.identity])
            state.entries[key.identity] = Entry(metric: metric)
            return (metric, true, true, nil)
          }
          if existing.metric.key.kind == key.kind, let metric = existing.metric as? Metric {
            state.entries[key.identity]!.liveHandles += 1
            state.entries[key.identity]!.undestroyedHandles += 1
            return (metric, false, true, nil)
          }
          let isFirstConflict = state.reportedConflicts.insert(key.identity).inserted
          return (create(key, nil), false, false, isFirstConflict ? existing.metric.key.kind : nil)
        }
    if result.isNew, key.droppedLabelCount > 0 {
      logger.warning(
        "Metric has more than \(MetricKey.maximumLabelCount) dimensions. Extra dimensions are dropped.",
        metadata: ["metric_type": "\(key.metricType)"])
    }
    if let conflictingKind = result.conflictingKind {
      logger.warning(
        "Metric is already registered with another kind and will not be exported.",
        metadata: [
          "metric_type": "\(key.metricType)",
          "kind": "\(key.kind)",
          "registered_kind": "\(conflictingKind)",
        ])
    }
    return (result.metric, result.isLeased)
  }

  /// Releases a lease. A metric without live handles is removed after its final value has been
  /// collected, once every handle is destroyed or the metric has expired.
  func release(_ metric: any ExportableMetric, destroy: Bool) {
    state.withLock { state in
      guard var entry = state.entries[metric.key.identity], entry.metric === metric else {
        return
      }
      entry.liveHandles = max(0, entry.liveHandles - 1)
      if destroy {
        entry.undestroyedHandles = max(0, entry.undestroyedHandles - 1)
      }
      state.entries[metric.key.identity] = entry
    }
  }

  /// Returns the points to export and removes metrics which are exported for the last time.
  ///
  /// Update counts are read before the points, so an update racing with the collect either is
  /// included in the exported point or keeps the metric for the next collect.
  func collect(endingAt endTime: Date) -> [MetricSnapshot] {
    let metrics = state.withLock { state in
      if !state.lastEndTimes.isEmpty {
        let cutoff = endTime.addingTimeInterval(-lastEndTimeRetention)
        state.lastEndTimes = state.lastEndTimes.filter { $0.value > cutoff }
      }
      return state.entries.values.map(\.metric)
    }
    let collected = metrics.map { metric in
      let updateCount = metric.updateCount
      return (metric: metric, updateCount: updateCount, point: metric.point(endingAt: endTime))
    }
    state.withLock { state in
      for (metric, updateCount, point) in collected {
        removeIfFinal(
          metric, updateCount: updateCount, isExported: point != nil, endTime: endTime,
          state: &state)
      }
    }
    return collected.compactMap { collected in
      collected.point.map { MetricSnapshot(key: collected.metric.key, point: $0) }
    }
  }

  private func removeIfFinal(
    _ metric: any ExportableMetric,
    updateCount: UInt64,
    isExported: Bool,
    endTime: Date,
    state: inout State
  ) {
    let identity = metric.key.identity
    guard var entry = state.entries[identity], entry.metric === metric else {
      return
    }
    if entry.lastActivity == nil || updateCount != entry.observedUpdateCount {
      entry.observedUpdateCount = updateCount
      entry.lastActivity = endTime
    }
    let hasUnexportedUpdates = !isExported && updateCount > 0
    let isRemovable =
      entry.liveHandles == 0
      && !hasUnexportedUpdates
      && metric.updateCount == updateCount
      && (entry.undestroyedHandles == 0 || isExpired(entry, endTime: endTime))
    guard isRemovable else {
      state.entries[identity] = entry
      return
    }
    state.entries[identity] = nil
    if isExported {
      state.lastEndTimes[identity] = endTime
    }
  }

  private func isExpired(_ entry: Entry, endTime: Date) -> Bool {
    guard let idleExpiration, idleExpiration.contains(entry.metric.key.kind),
      let lastActivity = entry.lastActivity
    else {
      return false
    }
    return endTime.timeIntervalSince(lastActivity) >= idleExpirationInterval
  }
}

extension Duration {

  fileprivate var timeInterval: TimeInterval {
    let (seconds, attoseconds) = components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}
