/// Configures when metrics which are no longer referenced are removed.
///
/// A metric is referenced while any `Counter`, `Timer`, etc. created for it is alive. Once all of
/// them are deallocated (for example after an inline `Counter(label:).increment()`) and the metric
/// hasn't been updated for `after`, its final value is exported and the time series is no longer
/// written. Creating the metric again starts a new cumulative interval.
public struct IdleExpiration: Sendable, Hashable {

  public struct Kinds: OptionSet, Sendable, Hashable {

    public let rawValue: UInt8

    public init(rawValue: UInt8) {
      self.rawValue = rawValue
    }

    /// `Counter` and `FloatingPointCounter`.
    public static let counters = Kinds(rawValue: 1 << 0)

    /// `Timer` and aggregating `Recorder`.
    public static let distributions = Kinds(rawValue: 1 << 1)

    /// `Meter` and non-aggregating `Recorder` (`Gauge`). Not included by default, since an inline
    /// `Meter` used to count up and down would lose its value when removed.
    public static let gauges = Kinds(rawValue: 1 << 2)
  }

  /// Time without updates before an unreferenced metric is removed. Must not be negative.
  ///
  /// Evaluated at each export, so `.zero` removes the metric at the first export after its last
  /// update.
  public var after: Duration

  /// Kinds of metrics which are removed when idle.
  public var kinds: Kinds

  public init(after: Duration = .zero, kinds: Kinds = [.counters, .distributions]) {
    self.after = after
    self.kinds = kinds
  }

  /// Removes counters and distributions at the first export after their last update.
  public static let `default` = IdleExpiration()

  func contains(_ kind: MetricKey.Kind) -> Bool {
    switch kind {
    case .counter, .floatingPointCounter:
      return kinds.contains(.counters)
    case .recorder, .timer:
      return kinds.contains(.distributions)
    case .gauge:
      return kinds.contains(.gauges)
    }
  }
}
