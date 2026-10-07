import GRPCCore
import GRPCNIOTransportHTTP2
import GoogleCloudAuth
import GoogleCloudAuthGRPC
import Logging
import NIOPosix
import RetryableTask

protocol TimeSeriesWriter: Sendable {

  /// Runs the underlying connections until `beginGracefulShutdown()` is called.
  func run() async throws

  func beginGracefulShutdown()

  func write(_ timeSeries: [Google_Monitoring_V3_TimeSeries], projectID: String) async throws
}

final class MetricServiceConnection: TimeSeriesWriter {

  private let logger = Logger(label: "metrics.write")

  let authorization: Authorization
  let client: Google_Monitoring_V3_MetricService.Client<HTTP2ClientTransport.Posix>

  private let grpcClient: GRPCClient<HTTP2ClientTransport.Posix>

  init(scopes: [Scope], authorizationProvider: GoogleCloudAuth.Provider) throws {
    self.authorization = Authorization(
      scopes: scopes,
      provider: authorizationProvider,
      eventLoopGroup: MultiThreadedEventLoopGroup.singleton
    )
    self.grpcClient = GRPCClient(
      transport: try .http2NIOPosix(
        target: .dns(host: "monitoring.googleapis.com"),
        transportSecurity: .tls,
        config: .defaults { config in
          config.backoff = .init(
            initial: .milliseconds(100),
            max: .seconds(1),
            multiplier: 1.6,
            jitter: 0.2
          )
          config.connection = .init(
            maxIdleTime: .seconds(30 * 60),
            keepalive: .init(
              time: .seconds(30),
              timeout: .seconds(5),
              allowWithoutCalls: true
            )
          )
        },
        serviceConfig: .init(
          methodConfig: [
            .init(
              names: [.init(service: "")],  // Empty service means all methods
              waitForReady: true,
              timeout: .seconds(20)
            )
          ]
        )
      ),
      interceptors: [
        AuthorizationClientInterceptor(authorization: authorization)
      ]
    )
    self.client = Google_Monitoring_V3_MetricService.Client(wrapping: grpcClient)
  }

  func run() async throws {
    do {
      try await grpcClient.runConnections()
    } catch let error as RuntimeError where error.code == .clientIsStopped {
      // Graceful shutdown began before the connections started running.
    }
    try await authorization.shutdown()
  }

  func beginGracefulShutdown() {
    grpcClient.beginGracefulShutdown()
  }

  func write(_ timeSeries: [Google_Monitoring_V3_TimeSeries], projectID: String) async throws {
    let request = Google_Monitoring_V3_CreateTimeSeriesRequest.with {
      $0.name = "projects/" + projectID
      $0.timeSeries = timeSeries
    }
    // Non-transient errors are not retried, since some of the time series in the request may
    // already have been written and would be rejected as out of order on retry.
    let result: Result<Void, any Error> = try await withRetryableTask(
      policy: JitteredExponentialBackoffRetryPolicy(),
      logger: logger
    ) {
      do {
        _ = try await self.client.createTimeSeries(request)
        return .success(())
      } catch let error as RPCError where !error.isTransient {
        return .failure(error)
      }
    }
    try result.get()
  }
}

extension RPCError {

  var isTransient: Bool {
    switch code {
    case .unavailable, .deadlineExceeded, .aborted, .internalError, .resourceExhausted, .unknown:
      return true
    default:
      return false
    }
  }
}

/// Retries with an exponentially increasing delay, randomized by ±50% to avoid many instances
/// retrying in lockstep.
struct JitteredExponentialBackoffRetryPolicy: RetryableTask.RetryPolicy {

  let maximumDelay: Duration
  let maximumRetries: Int

  private var delay: Duration
  private var retries = 0

  init(
    initialDelay: Duration = .milliseconds(500),
    maximumDelay: Duration = .seconds(8),
    maximumRetries: Int = 4
  ) {
    self.delay = initialDelay
    self.maximumDelay = maximumDelay
    self.maximumRetries = maximumRetries
  }

  var shouldRetry: Bool {
    retries < maximumRetries
  }

  mutating func beforeRetry() async throws {
    try await Task.sleep(for: delay * Double.random(in: 0.5...1.5))
    retries += 1
    delay = min(delay * 2, maximumDelay)
  }
}
