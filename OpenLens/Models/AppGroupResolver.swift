import Foundation

/// Resolves the App Group shared by the app and the Live Activity widget (ios18 branch).
///
/// Sideloading tools (SideStore/AltStore with a free Apple ID) re-sign the app and
/// rename the App Group, usually by appending the team ID, because group IDs are
/// unique across all developers. A hard-coded suite name would then silently point
/// at an unshared container and Live Activity buttons would lose the server
/// credentials. The group actually granted to this binary is read from its embedded
/// provisioning profile; Info.plist and the build-time default are fallbacks.
nonisolated enum AppGroupResolver {
    static let fallbackIdentifier = "group.net.wonded.openlens"

    static let identifier: String = {
        if let group = groupFromEmbeddedProfile() {
            return group
        }
        if let group = Bundle.main.object(forInfoDictionaryKey: "OpenLensAppGroup") as? String,
           group.hasPrefix("group."), !group.contains("$(") {
            return group
        }
        return fallbackIdentifier
    }()

    private static func groupFromEmbeddedProfile() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }

        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return nil }

        return groups.first { $0.hasPrefix("group.") && !$0.contains("*") }
    }
}
