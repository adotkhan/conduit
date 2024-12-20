/*
 * Copyright (c) 2024, Psiphon Inc.
 * All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

import Collections
import Foundation
import PsiphonTunnel
import Logging

extension Logging.Logger {
    static let conduitMan = Logger(label: "ConduitManager")
    static let psiphonTunnel = Logger(label: "PsiphonTunnel")
}

struct ActivitySeries: Equatable {
    let msBucketPeriod: UInt64
    let numBuckets: Int
    private(set) var bytesUp: Deque<Int>
    private(set) var bytesDown: Deque<Int>
    private(set) var connectingClients: Deque<Int>
    private(set) var connectedClients: Deque<Int>
    
    init(msBucketPeriod: UInt64, numBuckets: Int){
        self.msBucketPeriod = msBucketPeriod
        self.numBuckets = numBuckets
        
        bytesDown = Deque(repeating: 0, count: numBuckets)
        bytesUp = Deque(repeating: 0, count: numBuckets)
        connectingClients = Deque(repeating: 0, count: numBuckets)
        connectedClients = Deque(repeating: 0, count: numBuckets)
    }

    mutating private func pushDataPoints(
        _ bytesUp: Int,_ bytesDown: Int,
        _ connectingClients: Int,_ connectedClients: Int
    ) {
        self.bytesUp.removeFirst()
        self.bytesUp.append(bytesUp)
        self.bytesDown.removeFirst()
        self.bytesDown.append(bytesDown)
        self.connectingClients.removeFirst()
        self.connectingClients.append(connectingClients)
        self.connectedClients.removeFirst()
        self.connectedClients.append(connectedClients)
    }

    mutating func updateSeries(
        msSinceUpdate: UInt64, _ bytesUp: Int, _ bytesDown: Int,
        _ connectingClients: Int, _ connectedClients: Int
    ) {
        
        var elapsedBucketCount = Int(msSinceUpdate / self.msBucketPeriod) - 1
        if elapsedBucketCount > numBuckets {
            elapsedBucketCount = numBuckets
        }
        
        if elapsedBucketCount > 0 {
            (1...elapsedBucketCount).forEach { _ in pushDataPoints(0, 0, 0, 0) }
        }
        
        pushDataPoints(
            bytesUp, bytesDown,
            connectingClients, connectedClients
        )
    }
}

struct ActivityStats: Equatable {
    let startTime: TimeInterval
    private(set) var lastUpdate: TimeInterval
    private(set) var totalBytesUp: UInt64 = 0
    private(set) var totalBytesDown: UInt64 = 0
    private(set) var currentConnectingClients: Int = 0
    private(set) var currentConnectedClients: Int = 0
    private(set) var seriesFast: ActivitySeries = ActivitySeries(msBucketPeriod: 1000, numBuckets: 288)
    
    /// Time elapsed since Conduit start in milliseconds.
    var msElapsedTime: UInt64 {
        UInt64((lastUpdate - startTime) * 1000)
    }
    
    init() {
        startTime = Date().timeIntervalSinceReferenceDate
        lastUpdate = startTime
    }
    
    mutating func update(
        bytesUp: Int, bytesDown: Int,
        connectingClients: Int, connectedClients: Int
    ) {
        let now = Date().timeIntervalSinceReferenceDate

        self.totalBytesUp += UInt64(bytesUp)
        self.totalBytesDown += UInt64(bytesDown)
        self.currentConnectingClients = connectingClients
        self.currentConnectedClients = connectedClients

        // Round to nearest second to absorb minor timing gaps.
        let msSinceUpdate = UInt64(round(now - lastUpdate)) * 1000
        
        self.seriesFast.updateSeries(
            msSinceUpdate: msSinceUpdate,
            bytesUp, bytesDown,
            connectingClients, connectedClients
        )
        
        self.lastUpdate = now
    }
}

actor ConduitManager {
    
    protocol Listener {
        func onConduitStatusUpdate(
            _ status: ConduitManager.ConduitStatus,
            internetReachable: Bool?)
       
        func onInproxyProxyActivity(stats: ActivityStats)
        
        func onInproxyMustUpgrade()
    }
    
    enum ConduitStatus {
        case starting, started, stopping, stopped
    }
    
    // Note: PsiphonTunnel doesn't hold a strong reference to the delegate object.
    private var psiphonTunnelListener: PsiphonTunnelListener?
    private var psiphonTunnel: PsiphonTunnelAsyncWrapper?
    
    private var listener: Listener
    
    private(set) var conduitStatus: ConduitStatus = .stopped
    private(set) var activityStats: ActivityStats? = .none
    
    init(listener: Listener) {
        self.listener = listener
    }

    private func setConduitStatus(_ status: ConduitStatus) {
        self.conduitStatus = status
        
        self.listener.onConduitStatusUpdate(
            status,
            internetReachable: self.psiphonTunnel!.isInternetReachable)
    }
    
    func startConduit(_ params: ConduitParams) async throws {

        if conduitStatus == .starting {
            Logger.conduitMan.warning("Concurrent start requests are not permitted.")
            return
        }
        
        if psiphonTunnel == nil {
            psiphonTunnelListener = PsiphonTunnelListener(listener: self)
            psiphonTunnel = PsiphonTunnelAsyncWrapper(
                tunneledAppDelegate: self.psiphonTunnelListener!)
        }

        if conduitStatus == .started && psiphonTunnelListener!.isEqualConduitParams(params) {
            Logger.conduitMan.warning("Restart conduit with duplicate parameters denied.")
            return
        }
        
        setConduitStatus(.starting)
        
        // Maintain starting status to prevent race conditions.
        await psiphonTunnel!.stop()
        activityStats = .none
        
        let dynamicConfigs = PsiphonTunnelListener.DynamicConfigs(
            conduitParams: params,
            clientVersion: getClientVersion()
        )
        psiphonTunnelListener!.setConfigs(dynamicConfigs)
        
        let success = await psiphonTunnel!.start(forced: false)
        if success {
            setConduitStatus(.started)
            activityStats = ActivityStats()
            listener.onInproxyProxyActivity(stats: activityStats!)
        } else {
            setConduitStatus(.stopped)
            Logger.conduitMan.debug(
                "Psiphon tunnel start was unsuccessful.",
                metadata: ["conduitParams": "\(String(describing: params))"]
            )
            throw Err("Failed to start conduit through psiphon tunnel with given parameters.")
        }
    }
    
    func stopConduit() async {

        guard case .started = conduitStatus else {
            if .starting == conduitStatus {
                Logger.conduitMan.warning("Cannot stop conduit during starting process.")
            }
            return
        }
        
        guard let psiphonTunnel else {
            Logger.conduitMan.debug(
                "Missing initialized PsiphonTunnelAsyncWrapper.",
                metadata: ["conduitStatus": "started"]
            )
            return
        }
         
        setConduitStatus(.stopping)
        await psiphonTunnel.stop()
        setConduitStatus(.stopped)
        activityStats = .none
    }
    
    func updateActivityStats(
        connectingClients: Int, connectedClients: Int,
        bytesUp: Int, bytesDown: Int
    ) {
        
        guard activityStats != nil else {
            return
        }
        
        activityStats!.update(
            bytesUp: bytesUp, bytesDown: bytesDown,
            connectingClients: connectingClients, connectedClients: connectedClients)
        
        self.listener.onInproxyProxyActivity(stats: activityStats!)
    }

}

extension ConduitManager: PsiphonTunnelListener.Listener {
    
    nonisolated func onInternetReachabilityChanged(_ reachable: Bool) {
        Task {
            await self.listener.onConduitStatusUpdate(
                await self.conduitStatus,
                internetReachable: reachable)
        }
    }
    
    nonisolated func onInproxyProxyActivity(
        _ connectingClients: Int, connectedClients: Int,
        bytesUp: Int, bytesDown: Int
    ) {
        Task {
            await self.updateActivityStats(
                connectingClients: connectingClients, connectedClients: connectedClients,
                bytesUp: bytesUp, bytesDown: bytesDown)
        }
    }
    
    nonisolated func onInproxyMustUpgrade() {
        Task {
            await self.listener.onInproxyMustUpgrade()
            await self.stopConduit()
        }
    }
    
}


fileprivate final class PsiphonTunnelAsyncWrapper {
    
    let psiphonTunnel: PsiphonTunnel
    
    var isInternetReachable: Bool? {
        var pointer = NetworkReachabilityNotReachable
        let networkReachability: NetworkReachability? = withUnsafeMutablePointer(to: &pointer) { pointer in
            let success = psiphonTunnel.getNetworkReachabilityStatus(pointer)
            if success {
                return pointer.pointee
            } else {
                return nil
            }
        }
        return networkReachability.map { $0 != NetworkReachabilityNotReachable }
    }
    
    init(tunneledAppDelegate: TunneledAppDelegate) {
        psiphonTunnel = PsiphonTunnel.newPsiphonTunnel(tunneledAppDelegate)
    }
    
    func start(forced: Bool) async -> Bool {
        // PsiphonTunnel start blocks.
        let task = Task.detached {
            return self.psiphonTunnel.start(forced)
        }
        return await task.value
    }
    
    func stop() async {
        let task = Task.detached {
            self.psiphonTunnel.stop()
        }
        await task.value
    }
    
}


fileprivate final class PsiphonTunnelListener: NSObject, TunneledAppDelegate {
    
    protocol Listener {
        func onInternetReachabilityChanged(_ reachable: Bool)
        func onInproxyProxyActivity(
            _ connectingClients: Int, connectedClients: Int,
            bytesUp: Int, bytesDown: Int)
        func onInproxyMustUpgrade()
    }

    struct DynamicConfigs {
        let conduitParams: ConduitParams
        let clientVersion: String
    }
    
    private let listener: Listener
    private var dynamicConfigs: DynamicConfigs?
    
    init(listener: Listener) {
        self.listener = listener
    }
    
    func setConfigs(_ configs: DynamicConfigs) {
        self.dynamicConfigs = configs
    }
    
    func isEqualConduitParams(_ conduitParams: ConduitParams) -> Bool{
        return (self.dynamicConfigs?.conduitParams == conduitParams)
    }
    
    func getEmbeddedServerEntries() -> String? {
        do {
            let data = try Data(contentsOf: ResourceFile.embeddedServerEntries.url)
            return String(data: data, encoding: .utf8)
        } catch {
            Logger.conduitMan.critical("Failed to read embedded server entries")
            return nil
        }
    }
    
    func getPsiphonConfig() -> Any? {
        
        guard let dynamicConfigs else {
            fatalError()
        }
        
        do {
            var config: [String: Any?] = try defaultPsiphonConfig()
            
            config["UseNoticeFiles"] = [
                "RotatingFileSize": 1_000_000,
                "RotatingSyncFrequency": 0
            ]
            
            config["DisableLocalHTTPProxy"] = true
            config["DisableLocalSocksProxy"] = true
            config["EmitBytesTransferred"] = true
            config["ClientVersion"] = dynamicConfigs.clientVersion
            
            config["DisableTunnels"] = true
            config["InproxyEnableProxy"] = true
            
            // An ephemeral key will be generated if not set.
            if let privateKey = dynamicConfigs.conduitParams.privateKey {
                config["InproxyProxySessionPrivateKey"] = privateKey
            }
            
            config["InproxyMaxClients"] = dynamicConfigs.conduitParams.maxClients
            config["InproxyLimitUpstreamBytesPerSecond"] = dynamicConfigs.conduitParams.limitUpstream
            config["InproxyLimitDownstreamBytesPerSecond"] = dynamicConfigs.conduitParams.limitDownstream
            
            config["EmitInproxyProxyActivity"] = true
            
            return config
        } catch {
            Logger.conduitMan.error("getPsiphonConfig failed", metadata: ["error": "\(error)"])
            return nil
        }
    }
    
    func onInproxyProxyActivity(
        _ connectingClients: Int32, connectedClients: Int32,
        bytesUp: Int, bytesDown: Int
    ) {
        listener.onInproxyProxyActivity(
            Int(connectingClients), connectedClients: Int(connectedClients),
            bytesUp: bytesUp, bytesDown: bytesDown)
    }
    
    func onInproxyMustUpgrade() {
        listener.onInproxyMustUpgrade()
    }
    
    func onStartedWaitingForNetworkConnectivity() {
        // onInternetReachabilityChanged doesn't get called on first start,
        // so we need to listen to onStartedWaitingForNetworkConnectivity as well.
        listener.onInternetReachabilityChanged(false)
    }
    
    func onInternetReachabilityChanged(_ currentReachability: NetworkReachability) {
        let reachable = currentReachability != NetworkReachabilityNotReachable
        listener.onInternetReachabilityChanged(reachable)
    }

    func onDiagnosticMessage(_ message: String, withTimestamp timestamp: String) {
        Logger.psiphonTunnel.debug("\(message)")
    }
    
}
