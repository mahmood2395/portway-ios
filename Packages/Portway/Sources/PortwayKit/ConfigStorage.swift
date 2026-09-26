// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. Copyright © 2026 Portway.
//
// Where a config lives: the wg-quick text in the keychain (shared with the tunnel extension
// through the app group's access group), referenced from the VPN profile by a persistent
// reference. Adapted from wireguard-apple's Shared/Keychain.swift and
// NETunnelProviderProtocol+Extension.swift, iOS only.
//
// The private key therefore never sits in the VPN profile or in UserDefaults.

import Foundation
import NetworkExtension
import PortwayCore
import Security
import WireGuardKit

public enum ConfigKeychain {
    /// The last read's status. errSecInteractionNotAllowed means "not unlocked since boot", which
    /// the tunnel reports as such rather than as a broken config.
    nonisolated(unsafe) public private(set) static var lastStatus: OSStatus = errSecSuccess

    public static func open(_ ref: Data) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecValuePersistentRef: ref, kSecReturnData: true] as CFDictionary, &result)
        lastStatus = status
        guard status == errSecSuccess, let data = result as? Data else {
            log("Keychain", "open failed: \(status)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func store(_ text: String, name: String) -> Data? {
        let items: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrLabel: "Portway config: \(name)",
            kSecAttrAccount: name + ": " + UUID().uuidString,
            kSecAttrDescription: "wg-quick(8) config",
            kSecAttrService: PortwayEnvironment.appBundleID,
            kSecAttrAccessGroup: PortwayEnvironment.appGroupID,
            // Readable from the first unlock after boot until shutdown: the extension reconnects in
            // the background, screen locked. (Not before the first unlock — nothing is.)
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData: Data(text.utf8),
            kSecReturnPersistentRef: true,
        ]
        var ref: CFTypeRef?
        let status = SecItemAdd(items as CFDictionary, &ref)
        guard status == errSecSuccess, let data = ref as? Data else {
            log("Keychain", "store failed: \(status)")
            return nil
        }
        return data
    }

    public static func delete(_ ref: Data) {
        SecItemDelete([kSecValuePersistentRef: ref] as CFDictionary)
    }

    /// Removes keychain items no profile references any more (a crash between add and save).
    public static func deleteAll(except keep: Set<Data>) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword,
                                          kSecAttrService: PortwayEnvironment.appBundleID,
                                          kSecMatchLimit: kSecMatchLimitAll,
                                          kSecReturnPersistentRef: true] as CFDictionary, &result)
        guard status == errSecSuccess, let refs = result as? [Data] else { return }
        for ref in refs where !keep.contains(ref) { delete(ref) }
    }
}

extension NETunnelProviderProtocol {
    /// Stores the config in a NEW keychain item. The caller deletes the previous item only once
    /// the profile pointing at this one has been saved: deleting first would leave a saved profile
    /// pointing at nothing if the save then failed.
    public convenience init?(tunnelConfiguration: TunnelConfiguration) {
        self.init()
        guard let name = tunnelConfiguration.name else { return nil }
        providerBundleIdentifier = PortwayEnvironment.tunnelBundleID
        guard let ref = ConfigKeychain.store(tunnelConfiguration.asWgQuickConfig(), name: name) else { return nil }
        passwordReference = ref
        // The extension cannot see the profile's localizedDescription; it needs the name for the
        // disconnect ledger, the session identity and the snapshot.
        providerConfiguration = [Self.nameKey: name]
        let endpoints = tunnelConfiguration.peers.compactMap { $0.endpoint }
        serverAddress = endpoints.count == 1 ? endpoints[0].stringRepresentation
            : endpoints.isEmpty ? "Unspecified" : "Multiple endpoints"
    }

    public static let nameKey = "portway.name"

    public var tunnelName: String? { providerConfiguration?[Self.nameKey] as? String }

    public func asTunnelConfiguration(called name: String? = nil) -> TunnelConfiguration? {
        guard let ref = passwordReference, let text = ConfigKeychain.open(ref) else { return nil }
        return try? TunnelConfiguration(fromWgQuickConfig: text, called: name)
    }

    public func destroyConfigurationReference() {
        if let ref = passwordReference { ConfigKeychain.delete(ref) }
    }
}
