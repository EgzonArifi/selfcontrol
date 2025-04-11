import Cocoa
import NetworkExtension
import SystemExtensions
import os.log

class ViewController: NSViewController {
  
  enum Status {
    case stopped
    case indeterminate
    case running
  }
  
  var status: Status = .stopped
  
  // Get the Bundle for the system extension.
  lazy var extensionBundle: Bundle = {
    let extensionsDirectoryURL = URL(fileURLWithPath: "Contents/Library/SystemExtensions", relativeTo: Bundle.main.bundleURL)
    let extensionURLs: [URL]
    do {
      extensionURLs = try FileManager.default.contentsOfDirectory(at: extensionsDirectoryURL,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: .skipsHiddenFiles)
    } catch let error {
      fatalError("Failed to get contents of \(extensionsDirectoryURL.absoluteString): \(error.localizedDescription)")
    }
    guard let extensionURL = extensionURLs.first else {
      fatalError("Failed to find any system extensions")
    }
    guard let extensionBundle = Bundle(url: extensionURL) else {
      fatalError("Failed to create a bundle with URL \(extensionURL.absoluteString)")
    }
    return extensionBundle
  }()
  
  override func viewDidLoad() {
    super.viewDidLoad()
    // Additional setup if needed.
  }
  
  @IBAction func startProxy(_ sender: Any) {
    startTunnel()
  }
  
  @IBAction func stopProxy(_ sender: Any) {
    stopTunnel()
  }
  
  @IBAction func clear(_ sender: Any) {
    clearPreferences()
  }
  
  @IBAction func enable(_ sender: Any) {
    enableConfiguration()
  }
  
  @IBAction func disable(_ sender: Any) {
    let manager = NETransparentProxyManager()
    loadAndUpdatePreferences(using: manager) { manager in
      manager.isEnabled = false
    }
  }
  
  @IBAction func initialize(_ sender: Any) {
    guard let extensionIdentifier = extensionBundle.bundleIdentifier else {
      self.status = .stopped
      return
    }
    let activationRequest = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
    activationRequest.delegate = self
    OSSystemExtensionManager.shared.submitRequest(activationRequest)
  }
  
  @IBAction func getInfo(_ sender: Any) {
    NETransparentProxyManager.loadAllFromPreferences { (managers, error) in
      guard error == nil else {
        os_log("load error: %@", error!.localizedDescription)
        return
      }
      for manager in managers ?? [] {
        let session = manager.connection as! NETunnelProviderSession
        let request = "get_mapping".data(using: .utf8)
        do {
          try session.sendProviderMessage(request!) { (response: Data?) in
            guard let responseString = String(data: response ?? Data(), encoding: .utf8) else {
              return
            }
            os_log("response: %@", responseString)
          }
        } catch {}
      }
    }
  }
  
  // In this enableConfiguration() we now include sample HTTP websites.
  // For instance, "neverssl.com" is a known HTTP-only site.
  // The following block list includes both domain-only and domain+path rules.
  func enableConfiguration() {
    let manager = NETransparentProxyManager()
    loadAndUpdatePreferences(using: manager) { manager in
      let config = NETunnelProviderProtocol()
      config.providerBundleIdentifier = self.extensionBundle.bundleIdentifier
      
      // Example blocked patterns:
      // - "neverssl.com" will block all requests to neverssl.com (and subdomains)
      // - "example.com/forbidden" will block any HTTP request to example.com
      //   that has a URL path beginning with "/forbidden"
      // - "testhttp.com/secret" is another path–based block example.
      let blockedURLPatterns = [
        "http://www.testingmcafeesites.com/testcat_ac.html",            // Block entire domain
        "http://www.testingmcafeesites.com/testcat_al.html",    // Block only if the path begins with "/forbidden"
        "http://www.testingmcafeesites.com/testcat_an.html"       // Another path–based example
      ]
      
      config.providerConfiguration = [
        "ports": ["80", "443"],
        "tunnelRemoteAddress": "127.0.0.1",
        "blockedURLPatterns": blockedURLPatterns
      ]
      config.serverAddress = "http://127.0.0.1:8080"
      
      manager.localizedDescription = "proxy"
      manager.protocolConfiguration = config
      
      manager.isEnabled = true
    }
  }
  
  private func loadAndUpdatePreferences(using manager: NETransparentProxyManager, _ completionHandler: @escaping (NETransparentProxyManager) -> Void) {
    manager.loadFromPreferences { error in
      guard error == nil else {
        os_log("load error: %@", error!.localizedDescription)
        return
      }
      completionHandler(manager)
      manager.saveToPreferences { (error) in
        guard error == nil else {
          os_log("save error: %@", error!.localizedDescription)
          return
        }
        os_log("saved")
      }
    }
  }
  
  private func clearPreferences() {
    NETransparentProxyManager.loadAllFromPreferences { (managers, error) in
      guard error == nil else {
        os_log("load error: %@", error!.localizedDescription)
        return
      }
      for manager in managers ?? [] {
        manager.removeFromPreferences(completionHandler: nil)
      }
    }
  }
  
  private func startTunnel() {
    NETransparentProxyManager.loadAllFromPreferences { (managers, error) in
      guard error == nil else {
        os_log("load error: %@", error!.localizedDescription)
        return
      }
      for manager in managers ?? [] {
        os_log("startTunnel: manager %@", manager)
        do {
          try manager.connection.startVPNTunnel(options: [:])
        } catch {
          os_log("Error starting tunnel: %@", error.localizedDescription)
        }
      }
    }
  }
  
  private func stopTunnel() {
    NETransparentProxyManager.loadAllFromPreferences { (managers, error) in
      guard error == nil else {
        os_log("load error: %@", error!.localizedDescription)
        return
      }
      for manager in managers ?? [] {
        os_log("stopTunnel: manager %@", manager)
        manager.connection.stopVPNTunnel()
      }
    }
  }
}

extension ViewController: OSSystemExtensionRequestDelegate {
  func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
    os_log("Request completed with result: %d", result.rawValue)
    guard result == .completed else {
      os_log("Unexpected result %d for system extension request", result.rawValue)
      status = .stopped
      return
    }
    // enableConfiguration() can be called here after a successful activation.
  }
  
  func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
    os_log("System extension request failed: %@", error.localizedDescription)
    status = .stopped
  }
  
  func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    os_log("Extension %@ requires user approval", request.identifier)
  }
  
  func request(_ request: OSSystemExtensionRequest,
               actionForReplacingExtension existing: OSSystemExtensionProperties,
               withExtension extension: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
    os_log("Replacing extension %@ version %@ with version %@", request.identifier, existing.bundleShortVersion, `extension`.bundleShortVersion)
    return .replace
  }
}
