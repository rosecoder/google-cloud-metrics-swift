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

  /// Returns the point to export, or `nil` if there is nothing to export.
  func point(endingAt endTime: Date) -> MetricPoint?
}

/// Cloud Monitoring rejects cumulative points where the start time is not before the end time.
let minimumCumulativeInterval: TimeInterval = 0.001

final class MetricsRegistry: Sendable {

  private struct Entry {
    let metric: any ExportableMetric
    /// Number of handlers returned and not yet destroyed. Entries without references are
    /// removed after their final value has been collected.
    var references: Int
  }

  private struct State {
    var entries: [MetricKey.Identity: Entry] = [:]
    var reportedConflicts: Set<MetricKey.Identity> = []
  }

  private let logger: Logger
  private let state = Mutex(State())

  init(logger: Logger) {
    self.logger = logger
  }

  /// Returns the existing metric for the key, or stores and returns a newly created one.
  ///
  /// The same handler is returned for the same label and dimensions, so values are aggregated
  /// across all `Counter`, `Timer`, etc. instances using the same identity.
  ///
  /// If a metric of another kind is already registered for the same identity, a new metric
  /// which is never exported is returned, since Cloud Monitoring doesn't allow mixing kinds
  /// within a metric type.
  func metric<Metric: ExportableMetric>(
    for key: MetricKey,
    create: (MetricKey) -> Metric
  ) -> Metric {
    let result: (metric: Metric, isNew: Bool, conflictingKind: MetricKey.Kind?) = state.withLock {
      state in
      guard let existing = state.entries[key.identity] else {
        let metric = create(key)
        state.entries[key.identity] = Entry(metric: metric, references: 1)
        return (metric, true, nil)
      }
      if existing.metric.key.kind == key.kind, let metric = existing.metric as? Metric {
        state.entries[key.identity]!.references += 1
        return (metric, false, nil)
      }
      let isFirstConflict = state.reportedConflicts.insert(key.identity).inserted
      return (create(key), false, isFirstConflict ? existing.metric.key.kind : nil)
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
    return result.metric
  }

  /// Releases a handler. The metric is removed after its final value has been collected, unless
  /// it's requested again before that.
  func release(_ metric: (any ExportableMetric)?) {
    guard let metric else {
      return
    }
    state.withLock { state in
      guard let entry = state.entries[metric.key.identity], entry.metric === metric else {
        return
      }
      state.entries[metric.key.identity]!.references = max(0, entry.references - 1)
    }
  }

  func collect(endingAt endTime: Date) -> [MetricSnapshot] {
    let (metrics, released) = state.withLock { state in
      (
        state.entries.values.map(\.metric),
        state.entries.values.filter { $0.references == 0 }.map(\.metric)
      )
    }
    let snapshots = metrics.compactMap { metric in
      metric.point(endingAt: endTime).map { MetricSnapshot(key: metric.key, point: $0) }
    }
    if !released.isEmpty {
      state.withLock { state in
        for metric in released {
          if let entry = state.entries[metric.key.identity], entry.metric === metric,
            entry.references == 0
          {
            state.entries[metric.key.identity] = nil
          }
        }
      }
    }
    return snapshots
  }
}
