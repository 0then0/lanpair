import Foundation
import Network
import dnssd
import Darwin
#if os(macOS)
import Cocoa
import FlutterMacOS
#else
import UIKit
import Flutter
#endif

/// DNS-SD uses the OS responder and the selected interface, not a Dart mDNS implementation.
final class LanPairPlatform: NSObject, FlutterStreamHandler {
    private var events: FlutterEventSink?
    private var registration: DNSServiceRef?
    private var browser: DNSServiceRef?
    private var resolvers: [DNSServiceRef] = []
    private var addressQueries: [DNSServiceRef] = []
    private var resolving = Set<String>()
    private var resolved: [String: [String: Any]] = [:]
    private var session = ""
    private var device = ""
    private var permission = "unknown"
    private var permissionBrowser: NWBrowser?
    private let pathMonitor = NWPathMonitor()
    private var lastPath: String?
    private var observer: NSObjectProtocol?

    init(messenger: FlutterBinaryMessenger) {
        super.init()
        let methods = FlutterMethodChannel(name: "lanpair/platform", binaryMessenger: messenger)
        methods.setMethodCallHandler { [weak self] call, reply in
            guard let self else { reply(nil); return }
            switch call.method {
            case "capabilities": reply(self.capabilities())
            case "requestPermission": self.requestPermission(); reply(self.capabilities())
            case "openSettings":
                #if os(macOS)
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                #else
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                #endif
                reply(nil)
            case "acquireMulticast", "releaseMulticast": reply(nil)
            case "startDiscovery":
                guard let args = call.arguments as? [String: Any],
                      let session = args["sessionId"] as? String,
                      let device = args["deviceId"] as? String,
                      let port = args["port"] as? Int, (1...65535).contains(port),
                      !session.isEmpty, session.utf8.count <= 128,
                      !device.isEmpty, device.utf8.count <= 128 else {
                    reply(FlutterError(code: "invalid_arguments", message: "Invalid discovery parameters.", details: nil)); return
                }
                self.stopDiscovery()
                self.session = session; self.device = device
                let error = self.startDiscovery(port: port, index: UInt32(args["interfaceIndex"] as? Int ?? 0))
                if error == kDNSServiceErr_NoError { reply(nil) }
                else { reply(FlutterError(code: error == -65570 ? "permission_denied" : "dns_sd_unavailable",
                                          message: "DNS-SD operation could not start.", details: Int(error))) }
            case "stopDiscovery": self.stopDiscovery(); reply(nil)
            default: reply(FlutterMethodNotImplemented)
            }
        }
        FlutterEventChannel(name: "lanpair/discovery", binaryMessenger: messenger).setStreamHandler(self)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let signature = "\(path.status)-\(path.availableInterfaces.map { "\($0.name):\($0.index)" }.sorted())"
                if let previous = self.lastPath, previous != signature { self.emit(["type": "networkChanged"]) }
                self.lastPath = signature
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "org.lanpair.network-path"))
        #if os(macOS)
        let notification = NSApplication.didBecomeActiveNotification
        #else
        let notification = UIApplication.didBecomeActiveNotification
        #endif
        observer = Foundation.NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
            // There is no general Apple permission getter. Discard stale observations on return from Settings.
            self?.permission = "unknown"
            self?.emit(["type": "permission", "permission": "unknown"])
        }
    }

    private func capabilities() -> [String: Any] {
        #if os(macOS)
        let platform = "macos"
        let rawMulticast = true
        let limits: [String] = []
        #else
        let platform = "ios"
        // Enable only in an entitlement-approved, correctly provisioned build (see docs/platforms.md).
        let rawMulticast = Bundle.main.object(forInfoDictionaryKey: "LANPairRawMulticastEnabled") as? Bool ?? false
        let limits = rawMulticast ? [] : ["ios_multicast_entitlement_missing"]
        #endif
        var items: [String: [String]] = [:]
        var first: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&first) == 0 {
            var cursor = first
            while let item = cursor {
                defer { cursor = item.pointee.ifa_next }
                guard let address = item.pointee.ifa_addr,
                      address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) else { continue }
                let name = String(cString: item.pointee.ifa_name)
                if let text = numericAddress(address) { items[name, default: []].append(text) }
            }
            freeifaddrs(first)
        }
        return ["platform": platform, "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "permission": permission, "rawMulticast": rawMulticast, "discovery": true,
                "limitationCodes": limits, "interfaces": items.keys.sorted().map { name in
                    ["name": name, "index": Int(if_nametoindex(name)), "addresses": items[name] ?? []] as [String: Any]
                }]
    }

    private func emit(_ value: [String: Any]) { events?(value) }

    private func observeError(_ error: DNSServiceErrorType, operation: String) {
        if error == -65570 {
            permission = "denied"
            emit(["type": "permission", "permission": "denied"])
        }
        emit(["type": "error", "code": error == -65570 ? "permission_denied" : operation, "nativeCode": Int(error)])
    }

    private func requestPermission() {
        permissionBrowser?.cancel()
        let browser = NWBrowser(for: .bonjour(type: "_lanpair._tcp", domain: "local."), using: .tcp)
        permissionBrowser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            DispatchQueue.main.async {
                guard let self, self.permissionBrowser === browser else { return }
                if case .waiting(let error) = state, case .dns(let code) = error, code == -65570 {
                    self.permission = "denied"; self.emit(["type": "permission", "permission": "denied"])
                }
                // Ready is an observed browser state, not a universal permission API.
                if case .ready = state {
                    self.permission = "granted"; self.emit(["type": "permission", "permission": "granted"])
                }
            }
        }
        browser.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak browser] in
            if self?.permissionBrowser === browser { browser?.cancel(); self?.permissionBrowser = nil }
        }
    }

    private func startDiscovery(port: Int, index: UInt32) -> DNSServiceErrorType {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let name = "LP-\(session.prefix(16))-\(device.prefix(16))"
        let txtValues = ["session=\(session)", "device=\(device)"]
        var txt = Data()
        for value in txtValues { let bytes = Data(value.utf8); txt.append(UInt8(bytes.count)); txt.append(bytes) }
        let publishError = txt.withUnsafeBytes { bytes in
            DNSServiceRegister(&registration, 0, index, name, "_lanpair._tcp.", "local.", nil,
                               UInt16(port).bigEndian, UInt16(txt.count), bytes.baseAddress,
                               { _, _, error, name, _, _, context in
                guard let context else { return }
                let self_ = Unmanaged<LanPairPlatform>.fromOpaque(context).takeUnretainedValue()
                if error != 0 { self_.observeError(error, operation: "dns_sd_publish") }
                else { self_.emit(["type": "published", "name": name.map { String(cString: $0) } ?? ""]) }
            }, context)
        }
        if publishError != 0 { observeError(publishError, operation: "dns_sd_publish"); return publishError }
        if let registration { DNSServiceSetDispatchQueue(registration, .main) }
        let browseError = DNSServiceBrowse(&browser, 0, index, "_lanpair._tcp.", "local.",
            { _, flags, index, error, name, type, domain, context in
                guard let context else { return }
                let self_ = Unmanaged<LanPairPlatform>.fromOpaque(context).takeUnretainedValue()
                if error != 0 { self_.observeError(error, operation: "dns_sd_browse"); return }
                guard let name, let type, let domain else { return }
                let serviceName = String(cString: name)
                guard serviceName.hasPrefix("LP-\(self_.session.prefix(16))-") &&
                      serviceName != "LP-\(self_.session.prefix(16))-\(self_.device.prefix(16))" else { return }
                if flags & kDNSServiceFlagsAdd == 0 { self_.emit(["type": "removed", "name": serviceName]); return }
                self_.resolve(name: serviceName, type: String(cString: type), domain: String(cString: domain), index: index)
            }, context)
        if browseError == 0, let browser { DNSServiceSetDispatchQueue(browser, .main) }
        else if browseError != 0 { observeError(browseError, operation: "dns_sd_browse"); stopDiscovery() }
        return browseError
    }

    private func resolve(name: String, type: String, domain: String, index: UInt32) {
        guard resolving.count < 8, resolving.insert("\(name):\(index)").inserted else { return }
        var resolver: DNSServiceRef?
        let error = DNSServiceResolve(&resolver, 0, index, name, type, domain,
            { _, _, index, error, fullname, host, port, length, bytes, context in
                guard let context else { return }
                let self_ = Unmanaged<LanPairPlatform>.fromOpaque(context).takeUnretainedValue()
                if error != 0 { self_.observeError(error, operation: "dns_sd_resolve"); return }
                guard let host, let fullname else { return }
                let txt = bytes.map { Data(bytes: $0, count: Int(length)) } ?? Data()
                let fields = self_.decodeTXT(txt)
                guard fields["session"] == self_.session, let peer = fields["device"], peer != self_.device else { return }
                let hostname = String(cString: host)
                self_.resolved[hostname] = ["type": "resolved", "name": String(cString: fullname),
                                           "host": hostname, "port": Int(UInt16(bigEndian: port)),
                                           "sessionId": self_.session, "deviceId": peer,
                                           "interfaceIndex": Int(index), "addresses": [String]()]
                self_.queryAddresses(host: hostname, index: index)
            }, Unmanaged.passUnretained(self).toOpaque())
        if error == 0, let resolver { resolvers.append(resolver); DNSServiceSetDispatchQueue(resolver, .main) }
        else { observeError(error, operation: "dns_sd_resolve") }
    }

    private func queryAddresses(host: String, index: UInt32) {
        guard addressQueries.count < 8 else { return }
        var query: DNSServiceRef?
        let error = DNSServiceGetAddrInfo(&query, 0, index, 0, host,
            { _, flags, _, error, hostname, address, _, context in
                guard let context else { return }
                let self_ = Unmanaged<LanPairPlatform>.fromOpaque(context).takeUnretainedValue()
                if error != 0 { self_.observeError(error, operation: "dns_sd_resolve"); return }
                guard flags & kDNSServiceFlagsAdd != 0, let hostname, let address,
                      let text = self_.numericAddress(address) else { return }
                let host = String(cString: hostname)
                guard var info = self_.resolved[host] else { return }
                var addresses = info["addresses"] as? [String] ?? []
                if !addresses.contains(text) { addresses.append(text) }
                info["addresses"] = addresses; self_.resolved[host] = info
                self_.emit(info)
            }, Unmanaged.passUnretained(self).toOpaque())
        if error == 0, let query { addressQueries.append(query); DNSServiceSetDispatchQueue(query, .main) }
        else { observeError(error, operation: "dns_sd_resolve") }
    }

    private func numericAddress(_ address: UnsafePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buffer)
    }

    private func decodeTXT(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]; var offset = 0
        while offset < data.count {
            let length = Int(data[offset]); offset += 1
            guard offset + length <= data.count else { return [:] }
            let entry = String(decoding: data[offset..<(offset + length)], as: UTF8.self)
            if let separator = entry.firstIndex(of: "=") { result[String(entry[..<separator])] = String(entry[entry.index(after: separator)...]) }
            offset += length
        }
        return result
    }

    func stopDiscovery() {
        if let browser { DNSServiceRefDeallocate(browser) }; browser = nil
        if let registration { DNSServiceRefDeallocate(registration) }; registration = nil
        resolvers.forEach { DNSServiceRefDeallocate($0) }; resolvers.removeAll()
        addressQueries.forEach { DNSServiceRefDeallocate($0) }; addressQueries.removeAll()
        resolving.removeAll(); resolved.removeAll()
        permissionBrowser?.cancel(); permissionBrowser = nil
    }

    deinit { stopDiscovery(); pathMonitor.cancel(); if let observer { Foundation.NotificationCenter.default.removeObserver(observer) } }
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { self.events = events; return nil }
    func onCancel(withArguments arguments: Any?) -> FlutterError? { events = nil; return nil }
}
