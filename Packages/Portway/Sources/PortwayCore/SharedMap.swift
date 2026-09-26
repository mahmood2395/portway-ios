// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// A dictionary in the app group's UserDefaults, stored one key per entry.
//
// The app, the tunnel extension and the widgets are separate processes writing the same defaults.
// Read–modify–write of one big dictionary lets two of them overwrite each other (the app forgets a
// "not ours" mark while the extension records one; one of the two is lost). A single key's write is
// atomic across processes, so each entry gets its own: "<namespace>.<entry>".

import Foundation

public struct SharedMap<Value>: Sendable {
    public let namespace: String

    public init(_ namespace: String) { self.namespace = namespace }

    private var d: UserDefaults { PortwayEnvironment.defaults }
    private var prefix: String { namespace + "." }

    public subscript(_ key: String) -> Value? {
        get { d.object(forKey: prefix + key) as? Value }
        nonmutating set { d.set(newValue, forKey: prefix + key) }
    }

    public func remove(_ key: String) { d.removeObject(forKey: prefix + key) }

    public var keys: [String] {
        d.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    public func removeAll(where match: (String) -> Bool) {
        for key in keys where match(key) { remove(key) }
    }
}
