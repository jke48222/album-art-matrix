// How to read a wall's answer to a POST.
//
// In Shared/ because the widget keys' direct send (WallAddress.send, in
// WallIntents.swift) has to apply the same rule as the app's session, and
// that file also compiles into the widget and share targets.

import Foundation

/// An HTTP success can still carry rejected fields from an older wall.
enum WallAcknowledgement {
    static func accepted(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data.isEmpty }
        if json["error"] != nil { return false }
        if let rejected = json["rejected"] as? [String: Any], !rejected.isEmpty { return false }
        if let rejected = json["rejected"] as? [Any], !rejected.isEmpty { return false }
        return json["rejected"] == nil || (json["rejected"] as? [String: Any])?.isEmpty == true || (json["rejected"] as? [Any])?.isEmpty == true
    }

    /// What the wall turned down, by field. A reason is the wall's own words
    /// when it gave some (a timer command answers with a sentence), and empty
    /// when it only named the field.
    static func reasons(_ data: Data) -> [String: String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        if let rejected = json["rejected"] as? [String: Any] {
            for (key, value) in rejected { out[key] = value as? String ?? "" }
        } else if let names = json["rejected"] as? [String] {
            for key in names { out[key] = "" }
        }
        if let error = json["error"] as? String { out["error"] = error }
        return out
    }
}
