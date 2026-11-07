// The iOS radio for the mesh: Apple's Multipeer Connectivity, which finds nearby iPhones over
// Bluetooth and peer-to-peer Wi-Fi with no network around. Driven from Dart through one method
// channel in each direction (see lib/mesh/multipeer_transport.dart for the protocol).
//
// All state lives on the main queue: Flutter calls `handle` there and channel calls back into
// Dart must be made there, while Multipeer calls its delegates on a private queue, so every
// delegate method hops to main first.
import Flutter
import MultipeerConnectivity

class Multipeer: NSObject, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate, MCSessionDelegate {
  private static let serviceType = "nearby-pay"
  private let channel: FlutterMethodChannel
  private var session: MCSession?
  private var advertiser: MCNearbyServiceAdvertiser?
  private var browser: MCNearbyServiceBrowser?
  /// Phones in range that this one dials (see `dial`), by name, and a pending redial for each.
  private var dialable: [String: MCPeerID] = [:]
  private var redials: [String: Timer] = [:]

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.nearby/multipeer", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch (call.method, call.arguments) {
    case ("start", _):
      start()
      result(nil)
    case ("send", let args as [String: Any]):
      guard let peer = args["peer"] as? String, let data = args["data"] as? FlutterStandardTypedData else {
        return result(FlutterError(code: "args", message: "send needs peer and data", details: nil))
      }
      guard let session = session, let to = session.connectedPeers.first(where: { $0.displayName == peer }) else {
        return result(FlutterError(code: "send", message: "\(peer) is not connected", details: nil))
      }
      do {
        try session.send(data.data, toPeers: [to], with: .reliable)
        result(nil)
      } catch {
        result(FlutterError(code: "send", message: error.localizedDescription, details: nil))
      }
    case ("stop", _):
      stop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start() {
    stop()
    // Random per app start, so the advertisement does not carry a stable identity.
    let me = MCPeerID(displayName: String(format: "%08x", UInt32.random(in: .min ... .max)))
    let session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
    session.delegate = self
    let advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: nil, serviceType: Multipeer.serviceType)
    advertiser.delegate = self
    advertiser.startAdvertisingPeer()
    let browser = MCNearbyServiceBrowser(peer: me, serviceType: Multipeer.serviceType)
    browser.delegate = self
    browser.startBrowsingForPeers()
    self.session = session
    self.advertiser = advertiser
    self.browser = browser
  }

  private func stop() {
    redials.values.forEach { $0.invalidate() }
    redials = [:]
    dialable = [:]
    advertiser?.stopAdvertisingPeer()
    browser?.stopBrowsingForPeers()
    session?.disconnect()
    advertiser = nil
    browser = nil
    session = nil
  }

  /// Of two phones that see each other, the one with the smaller name dials, so they never both do.
  private func dials(_ peer: MCPeerID) -> Bool {
    guard let session = session else { return false }
    return session.myPeerID.displayName < peer.displayName
  }

  private func dial(_ name: String) {
    guard let peer = dialable[name], let session = session, let browser = browser,
      !session.connectedPeers.contains(where: { $0.displayName == name })
    else { return }
    browser.invitePeer(peer, to: session, withContext: nil, timeout: 30)
  }

  /// A dial that fails or a link that drops while the phone is still there would otherwise leave
  /// the two unconnected for good: Multipeer reports a phone once, when it comes into range.
  private func redial(_ name: String) {
    guard dialable[name] != nil, redials[name] == nil else { return }
    redials[name] = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
      self?.redials[name] = nil
      self?.dial(name)
    }
  }

  // MARK: advertising. Anyone running the app may connect: vouchers are signed, and relays verify before carrying.

  func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                  withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
    invitationHandler(session != nil, session)
  }

  // MARK: browsing

  func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
    DispatchQueue.main.async {
      guard self.dials(peerID) else { return }
      self.dialable[peerID.displayName] = peerID
      self.dial(peerID.displayName)
    }
  }

  func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
    DispatchQueue.main.async { self.dialable[peerID.displayName] = nil }
  }

  // MARK: the session

  func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
    DispatchQueue.main.async {
      switch state {
      case .connected: self.channel.invokeMethod("connected", arguments: peerID.displayName)
      case .notConnected:
        self.channel.invokeMethod("disconnected", arguments: peerID.displayName)
        self.redial(peerID.displayName)
      default: break
      }
    }
  }

  func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
    DispatchQueue.main.async {
      self.channel.invokeMethod("message", arguments: ["peer": peerID.displayName, "data": FlutterStandardTypedData(bytes: data)])
    }
  }

  // Streams and resources are not used.
  func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
  func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
  func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
