import Foundation
import Testing

@testable import GoogleCloudMetrics

@Suite struct DistributionBucketsTests {

  @Test func linearBounds() {
    let buckets = DistributionBuckets.linear(count: 3, width: 10, offset: 5)
    #expect(buckets.bounds == [5, 15, 25, 35])
  }

  @Test func exponentialBounds() {
    let buckets = DistributionBuckets.exponential(count: 3, growthFactor: 2, scale: 1)
    #expect(buckets.bounds == [1, 2, 4, 8])
  }

  @Test func explicitBounds() {
    let buckets = DistributionBuckets.explicit(bounds: [1, 10, 100])
    #expect(buckets.bounds == [1, 10, 100])
  }

  @Test(arguments: [
    (-1.0, 0),
    (0.5, 0),
    (1.0, 1),
    (1.5, 1),
    (2.0, 2),
    (7.9, 3),
    (8.0, 4),
    (1_000.0, 4),
  ])
  func bucketIndex(value: Double, expectedIndex: Int) {
    let bounds = DistributionBuckets.exponential(count: 3, growthFactor: 2, scale: 1).bounds
    #expect(DistributionBuckets.bucketIndex(for: value, bounds: bounds) == expectedIndex)
  }

  @Test func exponentialBoundsDoNotAccumulateRoundingErrors() {
    let bounds = DistributionBuckets.exponential(count: 150, growthFactor: 1.1, scale: 0.3).bounds
    for (index, bound) in bounds.enumerated() {
      #expect(bound == 0.3 * pow(1.1, Double(index)))
    }
  }

  @Test func boundsAreStrictlyIncreasing() {
    for buckets in [DistributionBuckets.defaultTimer, .defaultRecorder] {
      #expect(zip(buckets.bounds, buckets.bounds.dropFirst()).allSatisfy { $0 < $1 })
    }
  }

  @Test func maximumBucketCountIsAccepted() {
    #expect(DistributionBuckets.linear(count: 198, width: 1, offset: 0).bounds.count == 199)
  }

  @Test func zeroCountIsRejected() async {
    await #expect(processExitsWith: .failure) {
      _ = DistributionBuckets.linear(count: 0, width: 1, offset: 0)
    }
  }

  @Test func tooManyBucketsAreRejected() async {
    await #expect(processExitsWith: .failure) {
      _ = DistributionBuckets.exponential(count: 199, growthFactor: 2, scale: 1)
    }
  }

  @Test func nonPositiveWidthIsRejected() async {
    await #expect(processExitsWith: .failure) {
      _ = DistributionBuckets.linear(count: 10, width: 0, offset: 0)
    }
  }

  @Test func growthFactorOfOneIsRejected() async {
    await #expect(processExitsWith: .failure) {
      _ = DistributionBuckets.exponential(count: 10, growthFactor: 1, scale: 1)
    }
  }

  @Test func nonPositiveScaleIsRejected() async {
    await #expect(processExitsWith: .failure) {
      _ = DistributionBuckets.exponential(count: 10, growthFactor: 2, scale: 0)
    }
  }

  @Test func unorderedExplicitBoundsAreRejected() async {
    await #expect(processExitsWith: .failure) {
      _ = DistributionBuckets.explicit(bounds: [1, 3, 2])
    }
  }

  @Test func emptyExplicitBoundsAreRejected() async {
    await #expect(processExitsWith: .failure) {
      _ = DistributionBuckets.explicit(bounds: [])
    }
  }

  @Test func defaultTimerBucketsCoverMillisecondsToMinutes() {
    let bounds = DistributionBuckets.defaultTimer.bounds
    #expect(bounds.first == 0.1)
    #expect(bounds.last! > 15 * 60 * 1_000)
  }
}
