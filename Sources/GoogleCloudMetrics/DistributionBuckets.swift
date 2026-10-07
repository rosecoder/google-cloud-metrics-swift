import Foundation

/// Bucket layout used when exporting distributions (aggregating recorders and timers).
///
/// Every layout has an underflow bucket (values below the first bound) and an overflow bucket
/// (values at or above the last bound) in addition to its finite buckets. Cloud Monitoring
/// accepts at most 200 buckets in total.
public struct DistributionBuckets: Sendable, Hashable {

  enum Layout: Sendable, Hashable {
    case linear(count: Int, width: Double, offset: Double)
    case exponential(count: Int, growthFactor: Double, scale: Double)
    case explicit
  }

  /// Cloud Monitoring accepts at most 200 buckets, including the underflow and overflow buckets.
  public static let maximumBucketCount = 200

  let layout: Layout

  /// All bucket boundaries in increasing order. The number of buckets is `bounds.count + 1`.
  let bounds: [Double]

  private init(layout: Layout, bounds: [Double]) {
    precondition(
      bounds.count + 1 <= Self.maximumBucketCount,
      "Distributions can have at most \(Self.maximumBucketCount) buckets, including underflow and overflow."
    )
    precondition(bounds.allSatisfy(\.isFinite), "Bucket bounds must be finite.")
    precondition(
      zip(bounds, bounds.dropFirst()).allSatisfy { $0 < $1 },
      "Bucket bounds must be strictly increasing.")
    self.layout = layout
    self.bounds = bounds
  }

  /// `count` buckets of equal `width`, where the first finite bucket starts at `offset`.
  ///
  /// - Precondition: `count` is in `1...198` and `width` is greater than zero.
  public static func linear(count: Int, width: Double, offset: Double) -> DistributionBuckets {
    precondition(count >= 1, "Bucket count must be at least 1.")
    precondition(width > 0 && width.isFinite, "Bucket width must be finite and greater than zero.")
    precondition(offset.isFinite, "Bucket offset must be finite.")
    return DistributionBuckets(
      layout: .linear(count: count, width: width, offset: offset),
      bounds: (0...count).map { offset + width * Double($0) }
    )
  }

  /// `count` buckets where the lower bound of finite bucket `i` (1-indexed) is
  /// `scale * pow(growthFactor, i - 1)`.
  ///
  /// - Precondition: `count` is in `1...198`, `growthFactor` is greater than one and `scale` is
  ///   greater than zero.
  public static func exponential(count: Int, growthFactor: Double, scale: Double)
    -> DistributionBuckets
  {
    precondition(count >= 1, "Bucket count must be at least 1.")
    precondition(
      growthFactor > 1 && growthFactor.isFinite, "Growth factor must be finite and greater than one.")
    precondition(scale > 0 && scale.isFinite, "Scale must be finite and greater than zero.")
    return DistributionBuckets(
      layout: .exponential(count: count, growthFactor: growthFactor, scale: scale),
      bounds: (0...count).map { scale * pow(growthFactor, Double($0)) }
    )
  }

  /// Buckets with explicit bounds.
  ///
  /// - Precondition: `bounds` is non-empty, finite, strictly increasing and has at most 199
  ///   elements.
  public static func explicit(bounds: [Double]) -> DistributionBuckets {
    precondition(!bounds.isEmpty, "At least one bucket bound is required.")
    return DistributionBuckets(layout: .explicit, bounds: bounds)
  }

  /// Default buckets for timers: 0.1 ms up to about 18 minutes.
  public static let defaultTimer: DistributionBuckets = .exponential(
    count: 40, growthFactor: 1.5, scale: 0.1)

  /// Default buckets for aggregating recorders: 1 up to about 10^12.
  public static let defaultRecorder: DistributionBuckets = .exponential(
    count: 40, growthFactor: 2, scale: 1)

  /// Returns the index of the bucket `value` belongs in, where `0` is the underflow bucket.
  static func bucketIndex(for value: Double, bounds: [Double]) -> Int {
    var low = 0
    var high = bounds.count
    while low < high {
      let middle = (low + high) / 2
      if bounds[middle] <= value {
        low = middle + 1
      } else {
        high = middle
      }
    }
    return low
  }
}
