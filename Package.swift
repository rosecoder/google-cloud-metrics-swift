// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "google-cloud-metrics",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "GoogleCloudMetrics", targets: ["GoogleCloudMetrics"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-log.git", from: "1.4.2"),
    .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.5.0"),
    .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
    .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.0"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
    .package(url: "https://github.com/rosecoder/google-cloud-auth-swift.git", from: "1.3.2"),
    .package(url: "https://github.com/rosecoder/retryable-task.git", from: "1.1.2"),
    .package(
      url: "https://github.com/rosecoder/google-cloud-service-context.git", from: "0.0.2"),
  ],
  targets: [
    .target(
      name: "GoogleCloudMetrics",
      dependencies: [
        .product(name: "Logging", package: "swift-log"),
        .product(name: "CoreMetrics", package: "swift-metrics"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
        .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
        .product(name: "GoogleCloudAuth", package: "google-cloud-auth-swift"),
        .product(name: "GoogleCloudAuthGRPC", package: "google-cloud-auth-swift"),
        .product(name: "RetryableTask", package: "retryable-task"),
        .product(
          name: "GoogleCloudServiceContext", package: "google-cloud-service-context"),
      ]
    ),
    .testTarget(
      name: "GoogleCloudMetricsTests",
      dependencies: [
        "GoogleCloudMetrics",
        .product(name: "CoreMetrics", package: "swift-metrics"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        .product(name: "GoogleCloudAuthTesting", package: "google-cloud-auth-swift"),
      ]
    ),
  ]
)
