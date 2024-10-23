/*
 * Copyright (c) 2024, Psiphon Inc.
 * All rights reserved.
 */


import Foundation
import PsiphonTunnel
import OSLog


extension Logger {
    private static var subsystem = Bundle.main.bundleIdentifier!
    
    static let conduitModule = Logger(subsystem: subsystem, category: "ConduitModule")
    
    static let feedbackUploadService = Logger(subsystem: subsystem, category: "FeedbackUploadService")
}

/// A type that is used for cross-langauge interaction with JavaScript codebase.
protocol ReactNativeEncodable: Encodable {
    var asDictionary: [String: Any?] { get }
}

/// A type that is sent as an event back to JavaScript via the bridge.
protocol ReactNativeEvent: ReactNativeEncodable {
    static var eventName: String { get }
}

struct ReactProxyState: Codable {
    
    enum Status: String, Codable {
        case RUNNING, STOPPED, UNKNOWN
    }
    
    enum NetworkState: String, Codable {
        case HAS_INTERNET, NO_INTERNET
    }
    
    let status: Status
    let networkState: NetworkState?
    
}

extension ReactProxyState: ReactNativeEncodable {
    var asDictionary: [String : Any?] {
        [
            "status": status.rawValue,
            "networkState": networkState?.rawValue
        ]
    }
}

enum ReactProxyError: Error, Codable {
    case inProxyStartFailed
    case inProxyRestartFailed
    case inProxyMustUpgrade
}

extension ReactProxyError: ReactNativeEncodable {
    var asDictionary: [String : Any?] {
        let action: String = switch self {
        case .inProxyStartFailed: "inProxyStartFailed"
        case .inProxyRestartFailed: "inProxyRestartFailed"
        case .inProxyMustUpgrade: "inProxyMustUpgrade"
        }
        return [
            "action": action
        ]
    }
}

struct ReactInProxyActivityStats: Codable {
    
    struct DataByPeriod: Codable {
        let numBuckets: Int
        let bytesUp: [Int]
        let bytesDown: [Int]
        let connectingClients: [Int]
        let connectedClients: [Int]
        let bucketPeriod: String
    }
    
    /// Total elapsed time in milliseconds.
    let elapsedTime: UInt64
    
    /// Cumulative bytes uploaded.
    let totalBytesUp: UInt64
    
    /// Cumulative bytes downloaded.
    let totalBytesDown: UInt64
    
    /// Number of connecting clients.
    let currentConnectingClients: Int
    
    /// Number of connected clients.
    let currentConnectedClients: Int
    
    /// Time series arrays for multiple fields, where each index corresponds to a bucket.
    let dataByPeriod: DataByPeriod
}

extension ReactInProxyActivityStats: ReactNativeEncodable {
    var asDictionary: [String : Any?] {
        [
            "elapsedTime": elapsedTime,
            "totalBytesUp": totalBytesUp,
            "totalBytesDown": totalBytesDown,
            "currentConnectingClients": currentConnectingClients,
            "currentConnectedClients": currentConnectedClients,
            "dataByPeriod": dataByPeriod.asDictionary,
        ]
    }
}

extension ReactInProxyActivityStats.DataByPeriod: ReactNativeEncodable {
    var asDictionary: [String : Any?] {
        [
            bucketPeriod : [
                "numBuckets": numBuckets,
                "bytesUp": bytesUp,
                "bytesDown": bytesDown,
                "connectingClients": connectingClients,
                "connectedClients": connectedClients
            ]
        ]
    }
}

/// PsiphonVPNEvent represents the events sent back to JavaScript via the bridge.
enum ConduitEvent {
    case proxyState(ReactProxyState)
    case proxyError(ReactProxyError)
    case inProxyActivityStats(ReactInProxyActivityStats)
}

extension ConduitEvent: ReactNativeEvent {
    
    static var eventName: String {
        "ConduitEvent"
    }
    
    var asDictionary: [String: Any?] {
        switch self {
        case let .proxyState(proxyState):
            ["type": "proxyState", "data": proxyState.asDictionary]
        case let .proxyError(proxyError):
            ["type": "proxyError", "data": proxyError.asDictionary]
        case let .inProxyActivityStats(stats):
            ["type": "inProxyActivityStats", "data": stats.asDictionary]
        }
    }
    
}


// MARK: - ConduitModule

/// React Native module for managing the VPN.
@objc(ConduitModule)
final class ConduitModule: RCTEventEmitter {
    
    // Concurrency note:
    // Exported methods of this class (defined in ConduitModule.mm) are
    // called on the provided dispatch queue (methodQueue).
    // Hence all members of this class should be considered as being owned
    // by the given dispatch queue.
    
    var conduitManager: ConduitManager!
    
    var hasListeners: Bool = false
    
    // Dispatch queue used by React Native to call exported methods (after initialization).
    // This queue is not expected to be under contention, so use `.sync` to submit block for
    // synchronous execution to reuse the same thread.
    // Note that using `.sync` and targeting the same queue will result in a deadlock.
    let dispatchQueue: dispatch_queue_t

    override init() {
        dispatchQueue = DispatchQueue(label: "ca.psiphon.conduit.module", qos: .default)
        super.init()
        
        conduitManager = ConduitManager(listener: self)
        Task {
            await FeedbackUploadService.live.setListener(self)
        }
    }
    
    override var methodQueue: dispatch_queue_t! {
        return dispatchQueue
    }
    
    override func startObserving() {
        hasListeners = true
        Task {
            let status = await self.conduitManager.conduitStatus
            
            // Send first status update.
            self.onConduitStatusUpdate(status, internetReachable: true)
        }
    }
    
    override func stopObserving() {
        hasListeners = false
    }
    
    override func supportedEvents() -> [String]! {
        return [ConduitEvent.eventName]
    }
    
    func sendEvent(_ event: ConduitEvent) {
        sendEvent(withName: ConduitEvent.eventName, body: event.asDictionary)
        Logger.conduitModule.debug("ConduitEvent: \(String(describing: event))")
    }
    
}

// Exported native methods
extension ConduitModule {
    
    @objc(toggleInProxy:limitUpstream:limitDownstream:privateKey:withResolver:withRejecter:)
    func toggleInProxy(
        _ maxClients: Int, limitUpstream: Int, limitDownstream: Int, privateKey: String?,
        resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
    ) {
        Task {
            switch await self.conduitManager.conduitStatus {
            case .stopped:
                let params = ConduitParams(
                    maxClients: maxClients,
                    limitUpstream: limitUpstream,
                    limitDownstream: limitDownstream,
                    privateKey: privateKey
                )
                do {
                    let success = try await self.conduitManager.startConduit(params)
                    if !success {
                        sendEvent(.proxyError(.inProxyStartFailed))
                    }
                } catch {
                    sendEvent(.proxyError(.inProxyStartFailed))
                    Logger.conduitModule.error(
                        "Proxy start failed: \(String(describing: error), privacy: .public)")
                }
            case .started:
                await self.conduitManager.stopConduit()
            case .starting, .stopping:
                // no-op
                break
            }
            resolve(nil)
        }
    }

    @objc(paramsChanged:withResolver:withRejecter:)
    func paramsChanged(
        _ params: NSDictionary,
        resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
    ) {
        guard let maxClients = params["maxClients"] as? Int,
            let limitUpstream = params["limitUpstreamBytesPerSecond"] as? Int,
            let limitDownstream = params["limitDownstreamBytesPerSecond"] as? Int,
            let privateKey = params["inProxyPrivateKey"] as? String? else {
                reject("error", "Did not receive four valid key value pairs from params.", nil)
                return
            }
        
        Task {   
            switch await self.conduitManager.conduitStatus {
            case .stopping, .stopped:
                // no-op
                resolve(nil)
                
            case .starting:
                reject("error", "Cannot change parameters while Conduit is starting.", nil)
                return
                
            case .started:
                let params = ConduitParams(
                    maxClients: maxClients,
                    limitUpstream: limitUpstream,
                    limitDownstream: limitDownstream,
                    privateKey: privateKey
                ) 
                do {
                    let success = try await self.conduitManager.startConduit(params)
                    if !success {
                        sendEvent(.proxyError(.inProxyRestartFailed))
                    }
                    resolve(nil)
                } catch {
                    sendEvent(.proxyError(.inProxyRestartFailed))
                }
            }
        }
    }
    
    @objc(sendFeedback:withResolver:withRejecter:)
    func sendFeedback(
        _ inproxyId: String,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        
        do {
            // Read psiphon-tunnel-core notices.
            
            let dataRootDirectory = try getApplicationSupportDirectory()
            
            let tunnelCoreNoticesPath: [URL] = [
                // Return values are tagged _Nullable, but should never be nil.
                noticesFilePath(dataRootDirectory: dataRootDirectory),
                olderNoticesFilePath(dataRootDirectory: dataRootDirectory)
            ]
            
            let (tunnelCoreEntries, parseErrors) = try readDiagnosticLogFiles(
                TunnelCoreLog.self,
                paths: tunnelCoreNoticesPath,
                transform: DiagnosticEntry.create(from:))
            
            if parseErrors.count > 0 {
                Logger.conduitModule.error(
                    "Log parse errors: \(String(describing: parseErrors), privacy: .public)")
            }
            
            
            // Prepare Feedback Diagnostic Report
            
            let feedbackId = try generateFeedbackId()
            Logger.conduitModule.info("Preparing feedback report with ID = \(feedbackId, privacy: .public)")
            
            let psiphonConfig = try defaultPsiphonConfig()
            
            guard
                let propagationChannelId = psiphonConfig["PropagationChannelId"] as? String,
                let sponsorId = psiphonConfig["SponsorId"] as? String
            else {
                throw Err("psiphon config is missing PropagationChannelId or SponsorId")
            }
            
            let psiphonInfo =  PsiphonInfo(
                clientVersion: getClientVersion(),
                propagationChannelId: propagationChannelId,
                sponsorId: sponsorId,
                inproxyId: inproxyId
            )
            
            let report = FeedbackDiagnosticReport(
                metadata: Metadata(
                    id: feedbackId,
                    appName: "conduit",
                    platform: ClientPlatform.platformString,
                    date: Date()
                ),
                feedback: nil,
                diagnosticInfo: DiagnosticInfo(
                    systemInformation: SystemInformation(
                        build: DeviceInfo.gatherDeviceInfo(device: .current),
                        tunnelCoreBuildInfo: PsiphonTunnel.getBuildInfo(),
                        psiphonInfo: psiphonInfo,
                        isAppStoreBuild: true,
                        isJailbroken: false,
                        language: getLanguageMinimalIdentifier(),
                        // TODO: get networkTypeName
                        networkTypeName: "WIFI"),
                    diagnosticHistory: tunnelCoreEntries
                ))
            
            let json = String(data: try JSONEncoder().encode(report), encoding: .utf8)!
            
            // Upload diagnostic report.
            
            Task {
                do {
                    try await FeedbackUploadService.live.startUpload(
                        data: json,
                        psiphonConfig: psiphonConfig,
                        uploadPath: "")
                    
                    resolve(nil)
                    Logger.conduitModule.info("Finished uploading feedback diagnostic report.")
                } catch {
                    reject("error", "Feedback upload failed", nil)
                    Logger.conduitModule.error(
                        "Feedback upload failed: \(String(describing: error), privacy: .public)")
                }
            }
            
        } catch {
            reject("error", "Feedback upload failed", nil)
            Logger.conduitModule.error(
                "Feedback upload failed: \(String(describing: error), privacy: .public)")
        }
    }
    
    @objc(logInfo:msg:withResolver:withRejecter:)
    func logInfo(_ tag: String, msg: String, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        Logger.conduitModule.info("\(tag, privacy: .public): \(msg, privacy: .public)")
        resolve(nil)
    }
    
    @objc(logWarn:msg:withResolver:withRejecter:)
    func logWarn(_ tag: String, msg: String, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        Logger.conduitModule.info("\(tag, privacy: .public): \(msg, privacy: .public)")
        resolve(nil)
    }

    @objc(logError:msg:withResolver:withRejecter:)
    func logError(_ tag: String, msg: String, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        Logger.conduitModule.info("\(tag, privacy: .public): \(msg, privacy: .public)")
        resolve(nil)
    }

}


extension ConduitModule: ConduitManager.Listener {
    
    func onConduitStatusUpdate(_ status: ConduitManager.ConduitStatus,
                               internetReachable: Bool?) {
        
        let proxyStatus: ReactProxyState.Status = switch status {
        case .starting, .started: .RUNNING
        case .stopping, .stopped: .STOPPED
        }
        
        let networkState: ReactProxyState.NetworkState? = switch internetReachable {
        case .none: .none
        case .some(true): .HAS_INTERNET
        case .some(false): .NO_INTERNET
        }
        
        let proxyState = ReactProxyState(
            status: proxyStatus,
            networkState: networkState)
        
        sendEvent(.proxyState(proxyState))
    }
    
    func onInproxyProxyActivity(stats: ActivityStats) {
        sendEvent(
            .inProxyActivityStats(
                ReactInProxyActivityStats(
                    elapsedTime: stats.msElapsedTime,
                    totalBytesUp: stats.totalBytesUp,
                    totalBytesDown: stats.totalBytesDown,
                    currentConnectingClients: stats.currentConnectingClients,
                    currentConnectedClients: stats.currentConnectedClients,
                    dataByPeriod: ReactInProxyActivityStats.DataByPeriod(
                        numBuckets: stats.seriesFast.numBuckets,
                        bytesUp: Array(stats.seriesFast.bytesUp),
                        bytesDown: Array(stats.seriesFast.bytesDown),
                        connectingClients: Array(stats.seriesFast.connectingClients),
                        connectedClients: Array(stats.seriesFast.connectedClients),
                        bucketPeriod: "\(stats.seriesFast.msBucketPeriod)ms"
                    )
                )
            )
        )
    }
        
    func onInproxyMustUpgrade() {
        sendEvent(.proxyError(.inProxyMustUpgrade))
    }
}

extension ConduitModule: FeedbackUploadService.Listener {
    
    func onDiagnosticMessage(_ message: String, withTimestamp timestamp: String) {
        Logger.feedbackUploadService.info("DiagnosticMessage: \(timestamp, privacy: .public) \(message, privacy: .public)")
    }
    
}