import NetworkExtension
import os.log
import dnssd

/// FilterDataProvider is a NEFilterDataProvider subclass that intercepts flows and applies a test rule.
class FilterDataProvider: NEFilterDataProvider {
  // MARK: - Properties

  /// A dictionary for storing flows related to the same process.
  private var relatedFlows: [String: [NEFilterSocketFlow]] = [:]
  
  // MARK: - Initialization
  
  override init() {
    super.init()
  }
  
  // MARK: - Filter Lifecycle
  
  override func startFilter(completionHandler: @escaping (Error?) -> Void) {
    os_log("[EADBUG] FilterDataProvider: Starting filter", log: OSLog.default, type: .info)
    
    // Create a rule matching all outbound traffic.
    let networkRule = NENetworkRule(remoteNetwork: nil,
                                    remotePrefix: 0,
                                    localNetwork: nil,
                                    localPrefix: 0,
                                    protocol: .any,
                                    direction: .outbound)
    let filterRule = NEFilterRule(networkRule: networkRule, action: .filterData)
    let filterSettings = NEFilterSettings(rules: [filterRule], defaultAction: .allow)
    
    apply(filterSettings) { error in
      if let error = error {
        os_log("[EADBUG] Error applying filter settings: %@", log: OSLog.default, type: .error, error.localizedDescription)
      }
      completionHandler(error)
    }
  }
  
  override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    os_log("[EADBUG] FilterDataProvider: Stopping filter with reason %d", log: OSLog.default, type: .info, reason.rawValue)
    completionHandler()
  }
  
  // MARK: - Flow Handling
  
  /// Called for each new flow.
  override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
    os_log("[EADBUG] FilterDataProvider: handleNewFlow invoked", log: OSLog.default, type: .debug)

    guard let socketFlow = flow as? NEFilterSocketFlow else {
      os_log("[EADBUG] Not a socket flow. Allowing.", log: OSLog.default, type: .info)
      return .allow()
    }
    
    // Extract remote endpoint (if available).
    guard let remoteEndpoint = socketFlow.remoteEndpoint as? NWHostEndpoint else {
      os_log("[EADBUG] No valid remote endpoint. Allowing flow.", log: OSLog.default, type: .error)
      return .allow()
    }
    
    os_log("[EADBUG] Flow from remote endpoint: %@, URL: %@", log: OSLog.default, type: .debug, remoteEndpoint.description, flow.url?.description ?? "nil")
    debugPrint("Flow from remote endpoint: \(remoteEndpoint.description) \(flow.url?.description ?? "nil")")
    
    // Only process outbound traffic.
    if socketFlow.direction != .outbound {
      os_log("[EADBUG] Non-outbound traffic. Allowing.", log: OSLog.default, type: .info)
      return .allow()
    }
    
    // Process the flow and decide a verdict.
    let verdict = processEvent(for: socketFlow)
    os_log("[EADBUG] Verdict for flow: %@", log: OSLog.default, type: .debug, verdict.debugDescription)
    return verdict
  }
  
  /// Processes the flow and returns a verdict.
  /// This is a simplified test rule that blocks flows destined for "example.com".
  private func processEvent(for flow: NEFilterSocketFlow) -> NEFilterNewFlowVerdict {
    guard let endpoint = flow.remoteEndpoint as? NWHostEndpoint else {
      return .allow()
    }
    let host = (flow.remoteHostname ?? endpoint.hostname).lowercased()
    os_log("[EADBUG] This is endpoint.hostname: %{public}@ ", endpoint.hostname)
    os_log("[EADBUG] This is remoteHostname: %{public}@ ", flow.remoteHostname ?? "NOTHING")
    os_log("[EADBUG] This is localFlowEndpoint: %{public}@ ", flow.localFlowEndpoint?.debugDescription ?? "NOTHING")

    if host == "example.com" || host == "8.8.8.8" {
      os_log("[EADBUG] Test Rule: Blocking flow to %{public}@ ", host)
      return .drop()
    }
    // Optionally log other flows for debugging
    os_log("[EADBUG] Test Rule: Allowing flow to %@", log: OSLog.default, type: .info, host)
    return .allow()
  }

  
  // MARK: - (Optional) Handling Related Flows & Alerts
  
  /// Adds a flow to a list of related flows for a given key.
  private func addRelatedFlow(forKey key: String, flow: NEFilterSocketFlow) {
    os_log("[EADBUG] Adding related flow for key: %@", log: OSLog.default, type: .debug, key)
    if relatedFlows[key] == nil {
      relatedFlows[key] = []
    }
    relatedFlows[key]?.append(flow)
  }
  
  /// Processes related flows once a decision is made for a given key.
  private func processRelatedFlows(forKey key: String) {
    guard let flows = relatedFlows[key] else {
      os_log("[EADBUG] No related flows for key: %@", log: OSLog.default, type: .debug, key)
      return
    }
    for flow in flows {
      let verdict = processEvent(for: flow)
      resumeFlow(flow, with: verdict)
    }
    relatedFlows[key] = nil
  }
  
  /// A stub method for resuming a flow with a verdict.
  private func resumeFlow(_ flow: NEFilterSocketFlow, with verdict: NEFilterNewFlowVerdict) {
    // In a complete implementation, this would resume the paused flow with the provided verdict.
    os_log("[EADBUG] Resuming flow %@ with verdict %@", log: OSLog.default, type: .info, flow.debugDescription, verdict.debugDescription)
  }
  
  /// A stub method to simulate alerting the user.
  /// In a complete implementation, this might trigger an IPC to your app for user intervention.
  private func alertUser(for flow: NEFilterSocketFlow) {
    os_log("[EADBUG] Alert: User decision needed for flow %@", log: OSLog.default, type: .info, flow.debugDescription)
  }
}
