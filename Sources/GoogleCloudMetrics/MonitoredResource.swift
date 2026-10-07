/// The monitored resource all exported time series are attached to.
///
/// User-defined metrics only support a subset of resource types. See
/// [Monitored resources for user-defined metrics](https://cloud.google.com/monitoring/custom-metrics/creating-metrics#which-resource).
public struct MonitoredResource: Sendable, Hashable {

  public var type: String
  public var labels: [String: String]

  public init(type: String, labels: [String: String]) {
    self.type = type
    self.labels = labels
  }

  /// A `generic_task` resource.
  ///
  /// - Important: `taskID` must be unique for every running process, or multiple processes will
  ///   write to the same time series and have their points rejected.
  public static func genericTask(
    projectID: String,
    location: String,
    namespace: String,
    job: String,
    taskID: String
  ) -> MonitoredResource {
    MonitoredResource(
      type: "generic_task",
      labels: [
        "project_id": projectID,
        "location": location,
        "namespace": namespace,
        "job": job,
        "task_id": taskID,
      ]
    )
  }

  /// A `generic_node` resource.
  public static func genericNode(
    projectID: String,
    location: String,
    namespace: String,
    nodeID: String
  ) -> MonitoredResource {
    MonitoredResource(
      type: "generic_node",
      labels: [
        "project_id": projectID,
        "location": location,
        "namespace": namespace,
        "node_id": nodeID,
      ]
    )
  }
}
