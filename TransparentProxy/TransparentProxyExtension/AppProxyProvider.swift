import Cocoa
import NetworkExtension
import os.log

@available(macOS 11.0, *)
class AppProxyProvider: NETransparentProxyProvider {
    
    // Define the blocked URL components.
    // Only block if Host exactly equals this host AND the path exactly equals this path.
    let blockedHost = "www.testingmcafeesites.com"
    let blockedPath = "/testcat_ac.html"
    
    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("Starting proxy with options: %{public}@", options as? CVarArg ?? "")
        
        // Configure network settings from vendor data.
        let vendorData = options?["VendorData"] as? [String: Any]
        let ports = vendorData?["ports"] as! [String]
        let tunnelRemoteAddress = vendorData?["tunnelRemoteAddress"] as! String
        
        // Create a network rule for each configured port.
        let networkRules = ports.map { port -> NENetworkRule in
            let remoteNetwork = NWHostEndpoint(hostname: "0.0.0.0", port: port)
            return NENetworkRule(remoteNetwork: remoteNetwork,
                                 remotePrefix: 0,
                                 localNetwork: nil,
                                 localPrefix: 0,
                                 protocol: .TCP,
                                 direction: .outbound)
        }
        
        let proxySettings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)
        proxySettings.includedNetworkRules = networkRules
        
        setTunnelNetworkSettings(proxySettings) { error in
            if let applyError = error {
                os_log("Failed to apply tunnel settings: %{public}@", applyError.localizedDescription)
            }
            completionHandler(error)
        }
    }
    
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("Stopping proxy")
        completionHandler()
    }
    
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // Only handle TCP flows; allow non-TCP flows.
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            os_log("New TCP flow: remoteEndpoint=%{public}@", tcpFlow.remoteEndpoint)
            
            if let hostEndpoint = tcpFlow.remoteEndpoint as? NWHostEndpoint,
               hostEndpoint.port == "80" {
                // For HTTP flows, open the connection immediately and then inspect the header.
                tcpFlow.open(withLocalEndpoint: nil) { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        os_log("Error opening TCP flow: %{public}@", error.localizedDescription)
                        tcpFlow.closeReadWithError(error)
                        tcpFlow.closeWriteWithError(error)
                        return
                    }
                    os_log("TCP flow opened; starting header inspection with a timeout.")
                    self.inspectHTTPHeaderAndForward(tcpFlow)
                }
            } else {
                // For non-HTTP flows, open and forward without header inspection.
                os_log("Non-HTTP flow on port %{public}@ – forwarding directly.",
                       (tcpFlow.remoteEndpoint as? NWHostEndpoint)?.port ?? "unknown")
                tcpFlow.open(withLocalEndpoint: nil) { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        os_log("Error opening non-HTTP TCP flow: %{public}@", error.localizedDescription)
                        tcpFlow.closeReadWithError(error)
                        tcpFlow.closeWriteWithError(error)
                        return
                    }
                    self.forwardDataInBothDirections(tcpFlow)
                }
            }
        }
        
        return true
    }
    
    /// Inspects the HTTP header with a timeout. If data arrives quickly, it will be parsed and checked;
    /// otherwise, forwarding starts.
    private func inspectHTTPHeaderAndForward(_ tcpFlow: NEAppProxyTCPFlow) {
        // Create a DispatchWorkItem that fires after a short timeout
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            os_log("Header inspection timeout reached; proceeding with forwarding without header processing.")
            self.forwardDataInBothDirections(tcpFlow)
        }
        // Schedule the timeout (adjust the deadline if needed)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1, execute: timeoutItem)
        
        tcpFlow.readData { [weak self] data, error in
            guard let self = self else { return }
            
            // Cancel the timeout – we got a response.
            timeoutItem.cancel()
            
            if let error = error {
                os_log("Error reading HTTP header data: %{public}@", error.localizedDescription)
                self.forwardDataInBothDirections(tcpFlow)
                return
            }
            
            if let data = data, !data.isEmpty {
                os_log("Received %d bytes of HTTP header data.", data.count)
                if let requestStr = String(data: data, encoding: .utf8) {
                    os_log("HTTP request text: %{public}@", requestStr)
                    
                    let lines = requestStr.components(separatedBy: "\r\n")
                    if let requestLine = lines.first {
                        os_log("Parsed request line: %{public}@", requestLine)
                        let parts = requestLine.split(separator: " ")
                        if parts.count >= 2 {
                            let requestPath = String(parts[1]).lowercased()
                            os_log("Extracted request path: %{public}@", requestPath)
                            
                            // Look for the Host header.
                            var hostHeader: String?
                            for line in lines {
                                if line.lowercased().hasPrefix("host:") {
                                    // Drop the first 5 characters ("Host:") then trim whitespace and lower case.
                                    hostHeader = String(line.dropFirst(5))
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                        .lowercased()
                                    // If the host contains a port (e.g. "www.example.com:80"), extract only the host.
                                    if let hostComponent = hostHeader?.components(separatedBy: ":").first {
                                        hostHeader = hostComponent
                                    }
                                    os_log("Found Host header: %{public}@", hostHeader!)
                                    break
                                }
                            }
                            
                            // Block only if the host and path exactly match.
                            if let hostHeader = hostHeader,
                               hostHeader == self.blockedHost.lowercased(),
                               requestPath == self.blockedPath.lowercased() {
                                os_log("Blocking HTTP request for URL: http://%{public}@%@", hostHeader, requestPath)
                                tcpFlow.closeReadWithError(NSError(domain: "ProxyBlock", code: -1, userInfo: nil))
                                tcpFlow.closeWriteWithError(NSError(domain: "ProxyBlock", code: -1, userInfo: nil))
                                return
                            } else {
                                os_log("Request allowed for host: %{public}@, path: %{public}@", hostHeader ?? "nil", requestPath)
                            }
                        } else {
                            os_log("Request line does not have expected components.")
                        }
                    } else {
                        os_log("No request line found in HTTP header data.")
                    }
                } else {
                    os_log("Unable to decode HTTP header data as UTF-8.")
                }
                // Forward the received header data then continue reading.
                self.forwardDataInBothDirections(tcpFlow, initialData: data)
            } else {
                os_log("HTTP header read returned empty; proceeding with data forwarding.")
                self.forwardDataInBothDirections(tcpFlow)
            }
        }
    }
    
    /// Forwards data in both directions, optionally writing the initial header data first.
    private func forwardDataInBothDirections(_ tcpFlow: NEAppProxyTCPFlow, initialData: Data? = nil) {
        if let initialData = initialData, !initialData.isEmpty {
            os_log("Forwarding initial %d bytes of header data.", initialData.count)
            tcpFlow.write(initialData) { error in
                if let error = error {
                    os_log("Error writing initial data: %{public}@", error.localizedDescription)
                    tcpFlow.closeReadWithError(error)
                    tcpFlow.closeWriteWithError(error)
                    return
                }
                self.continueForwarding(tcpFlow)
            }
        } else {
            continueForwarding(tcpFlow)
        }
    }
    
    /// Continuously reads from the TCP flow and writes data to the remote endpoint.
    private func continueForwarding(_ tcpFlow: NEAppProxyTCPFlow) {
        tcpFlow.readData { [weak self] data, error in
            guard let self = self else { return }
            
            if let error = error {
                os_log("Error during data forwarding: %{public}@", error.localizedDescription)
                tcpFlow.closeReadWithError(error)
                tcpFlow.closeWriteWithError(error)
                return
            }
            
            guard let data = data, !data.isEmpty else {
                os_log("No more data from client; closing connection.")
                tcpFlow.closeWriteWithError(nil)
                return
            }
            
            os_log("Forwarding %d bytes from client to server.", data.count)
            tcpFlow.write(data) { error in
                if let error = error {
                    os_log("Error writing data to server: %{public}@", error.localizedDescription)
                    tcpFlow.closeReadWithError(error)
                    tcpFlow.closeWriteWithError(error)
                } else {
                    self.continueForwarding(tcpFlow)
                }
            }
        }
    }
}
