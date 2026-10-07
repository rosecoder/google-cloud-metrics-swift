import Testing

@testable import GoogleCloudMetrics

@Suite struct TimeSeriesEncoderTests {

  @Test(arguments: [
    ("http_requests", "custom.googleapis.com/http_requests"),
    ("http.server.duration", "custom.googleapis.com/http.server.duration"),
    ("app/queue/size", "custom.googleapis.com/app/queue/size"),
    ("my-metric name", "custom.googleapis.com/my_metric_name"),
    ("åäö", "custom.googleapis.com/___"),
    ("/app//queue/", "custom.googleapis.com/app/queue"),
    ("", "custom.googleapis.com/unnamed"),
    ("/", "custom.googleapis.com/unnamed"),
  ])
  func metricType(label: String, expected: String) {
    #expect(MetricKey.metricType(label: label, prefix: "custom.googleapis.com/") == expected)
  }

  @Test(arguments: [
    ("method", "method"),
    ("statusCode", "statusCode"),
    ("http.method", "http_method"),
    ("1st", "key_1st"),
    ("_private", "key__private"),
    ("", "key"),
  ])
  func labelKey(key: String, expected: String) {
    #expect(MetricKey.labelKey(key) == expected)
  }

  @Test func labelKeyIsTruncated() {
    let key = String(repeating: "a", count: 150)
    #expect(MetricKey.labelKey(key).count == 100)
  }

  @Test func labelValueIsTruncatedOnCharacterBoundary() {
    let value = String(repeating: "å", count: 600)  // 2 bytes per character
    let truncated = MetricKey.labelValue(value)
    #expect(truncated.utf8.count == 1024)
    #expect(truncated.count == 512)
  }

  @Test func shortLabelValueIsUnchanged() {
    #expect(MetricKey.labelValue("GET") == "GET")
  }

  @Test func distributionOmitsTrailingZeroBucketCounts() {
    let distribution = TimeSeriesEncoder.distribution(
      DistributionSnapshot(
        count: 2,
        mean: 1,
        sumOfSquaredDeviation: 0,
        bucketCounts: [0, 2, 0, 0],
        buckets: .explicit(bounds: [1, 2, 3])
      ))
    #expect(distribution.bucketCounts == [0, 2])
  }

  @Test func exponentialBucketOptions() {
    let distribution = TimeSeriesEncoder.distribution(
      DistributionSnapshot(
        count: 1,
        mean: 1,
        sumOfSquaredDeviation: 0,
        bucketCounts: [0, 1],
        buckets: .exponential(count: 10, growthFactor: 2, scale: 0.5)
      ))
    #expect(distribution.bucketOptions.exponentialBuckets.numFiniteBuckets == 10)
    #expect(distribution.bucketOptions.exponentialBuckets.growthFactor == 2)
    #expect(distribution.bucketOptions.exponentialBuckets.scale == 0.5)
  }
}
