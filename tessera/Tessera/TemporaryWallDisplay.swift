import SwiftUI

/// Confirmed, expiring previews. Never enters the offline outbox.
@MainActor @Observable final class TemporaryWallDisplay {
    private(set) var token: String?
    private(set) var purpose: String?
    private(set) var secondsRemaining: Double?
    private(set) var busy = false
    var problem: String?
    /// Another screen's check (calibration, panel, guests, first run) owns the
    /// wall. Set only while this object holds nothing of its own.
    private(set) var occupiedBy: String?
    var active: Bool { token != nil }
    private var host: String?
    private var duration: Double = 300
    private var revision = 0
    private var attemptedToken: String?
    private var attemptedHost: String?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private struct Receipt: Decodable {
        var active: Bool
        var token: String?
        var purpose: String?
        var seconds_remaining: Double?
    }

    func show(on wall: WallSession, pixels: [UInt8], purpose: String,
              seconds: Double = 300, patch: [String: Double] = [:]) async -> Bool {
        // A hide or an earlier change may still be on its way. Let it land
        // first, the same way end() does, instead of refusing the tap.
        await waitUntilIdle()
        guard wall.link.isLive else {
            problem = "Connect to your wall first."
            return false
        }
        guard Panel.square(pixels.count) != nil else {
            problem = "This could not be prepared for the wall."
            return false
        }
        let target = wall.host
        if let host, host != target { clear() }
        let id = token ?? attemptedToken ?? UUID().uuidString
        attemptedToken = id
        attemptedHost = target
        duration = seconds
        return await write(wall: wall, host: target, path: "/display-session", body: [
            "token": id, "purpose": purpose, "seconds": seconds,
            "px": Data(pixels).base64EncodedString(), "patch": patch
        ])
    }

    func update(on wall: WallSession, patch: [String: Double] = [:], pixels: [UInt8]? = nil) async -> Bool {
        guard let token, let purpose, let host, host == wall.host else {
            problem = "This check has ended. Start it again."
            return false
        }
        var body: [String: Any] = ["token": token, "purpose": purpose, "seconds": duration, "patch": patch]
        if let pixels { body["px"] = Data(pixels).base64EncodedString() }
        return await write(wall: wall, host: host, path: "/display-session", body: body)
    }

    func end(on wall: WallSession, keep: [String: Double] = [:]) async -> Bool {
        await waitUntilIdle()
        guard let token = token ?? attemptedToken, let host = host ?? attemptedHost else { return keep.isEmpty }
        // Finish only the wall that accepted this session, even after navigation
        // changes the current endpoint. Its own timeout is the fallback.
        return await write(wall: wall, host: host, path: "/display-session/end", body: ["token": token, "keep": keep])
    }

    func refresh(on wall: WallSession, adopting purpose: String? = nil) async {
        guard !busy, wall.link.isLive else { return }
        let target = wall.host
        let version = revision
        guard let url = URL(string: "http://\(target)/display-session") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !busy, revision == version, wall.host == target, (response as? HTTPURLResponse)?.statusCode == 200,
                  let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { return }
            if receipt.active && (receipt.token != token || host != target) &&
                (receipt.token != attemptedToken || attemptedHost != target) {
                guard token == nil, let purpose, receipt.purpose == purpose else {
                    // Only a preview this screen held or tried to start can
                    // have "ended". Otherwise another check simply owns the wall.
                    let hadOurs = token != nil || attemptedToken != nil
                    clear()
                    occupiedBy = receipt.purpose ?? "check"
                    problem = hadOurs ? "Something else took over the wall, so this check has ended." : nil
                    return
                }
            }
            // The wall confirms a session this screen holds or tried to start
            // (a start whose reply timed out, say), so an earlier "did not
            // confirm" is out of date. An idle answer keeps the message: a
            // refused start must stay explained.
            if receipt.active { problem = nil }
            accept(receipt, host: target)
        } catch { /* A missed refresh cannot pretend an acknowledged display ended. */ }
    }

    private func write(wall: WallSession, host: String, path: String, body: [String: Any]) async -> Bool {
        guard !busy, let url = URL(string: "http://\(host)\(path)") else { return false }
        busy = true
        revision += 1
        problem = nil
        defer {
            busy = false
            let pending = waiters; waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                problem = object?["error"] as? String ?? "The wall could not make this change. Try again."
                // The wall answered, so a start it refused was never taken.
                attemptedToken = nil
                attemptedHost = nil
                // 400 or 409 to a change of a session this screen held means
                // the wall no longer has it (it expired, or another check
                // took over). A refused save (503) keeps it for a retry.
                if token != nil, status == 400 || status == 409 {
                    clear()
                    if !path.hasSuffix("/end") { problem = "This check has ended on the wall. Start it again." }
                }
                return false
            }
            let receipt = try JSONDecoder().decode(Receipt.self, from: data)
            let valid = path.hasSuffix("/end") ? !receipt.active :
                receipt.active && receipt.token == body["token"] as? String && receipt.purpose == body["purpose"] as? String
            guard valid else { problem = "The wall did not confirm this. Try again."; return false }
            attemptedToken = nil
            attemptedHost = nil
            accept(receipt, host: host)
            if wall.host == host { await wall.poll() }
            return true
        } catch {
            problem = "The wall did not confirm. Check your connection and try again. Checks on the wall end on their own."
            return false
        }
    }

    private func waitUntilIdle() async {
        guard busy else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func accept(_ receipt: Receipt, host: String) {
        occupiedBy = nil
        if receipt.active {
            token = receipt.token
            purpose = receipt.purpose
            secondsRemaining = receipt.seconds_remaining
            self.host = host
        } else { clear() }
    }

    private func clear() {
        token = nil
        purpose = nil
        secondsRemaining = nil
        host = nil
        attemptedToken = nil
        attemptedHost = nil
    }
}
