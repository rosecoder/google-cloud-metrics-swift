// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "google-cloud-metrics",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "GoogleCloudMetrics", targets: ["GoogleCloudMetrics"])
  ],
  targets: [
    .target(name: "GoogleCloudMetrics"),
    .testTarget(name: "GoogleCloudMetricsTests", dependencies: ["GoogleCloudMetrics"]),
  ]
)
