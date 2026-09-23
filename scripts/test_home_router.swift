import Foundation

@main struct RouterTests {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ condition: Bool, _ name: String) {
            checks.append(["name": name, "passed": condition])
        }
        let early = HomeRouter()
        early.present(.onboarding)
        early.present(.settings)
        check(early.sheet == .settings && early.cover == nil && early.pending == nil,
              "first launch settings replaces unpresented onboarding without awaiting dismissal")
        check(early.visible == .settings && early.presented == nil,
              "a requested screen does not claim to have appeared")
        early.didPresent(.onboarding)
        check(early.presented == nil && early.sheet == .settings,
              "superseded cover appearance cannot take ownership of the new sheet")
        early.didDismiss()
        check(early.sheet == .settings && early.visible == .settings,
              "dismissal without appeared content cannot discard a pending presentation")
        early.present(.studio)
        check(early.cover == .studio && early.sheet == nil && early.pending == nil,
              "an unpresented sheet can be replaced immediately by a cover")
        early.present(.onboarding)
        check(early.cover == .onboarding && early.visible == .onboarding && early.pending == nil,
              "an unpresented cover can be replaced by another cover")
        early.present(.onboarding)
        check(early.cover == .onboarding && early.pending == nil,
              "repeated requests before appearance do not schedule another presentation")
        early.dismiss()
        check(early.visible == nil && early.pending == nil && early.cover == nil && early.sheet == nil,
              "dismiss before appearance releases the request immediately")
        early.didPresent(.onboarding)
        early.didDismiss()
        check(early.presented == nil && early.visible == nil,
              "late lifecycle callbacks cannot revive a canceled unpresented request")
        early.present(.settings)
        check(early.sheet == .settings && early.pending == nil,
              "a canceled unpresented route does not block a later request")

        let router = HomeRouter()
        router.present(.settings)
        check(router.sheet == .settings && router.cover == nil, "settings uses one sheet")
        router.didPresent(.settings)
        check(router.presented == .settings, "sheet appearance confirms presentation ownership")
        router.present(.studio)
        check(router.sheet == nil && router.cover == nil && router.pending == .studio,
              "studio waits for settings dismissal")
        check(router.presented == .settings && router.visible == .settings,
              "the outgoing sheet retains ownership until dismissal completes")
        router.didDismiss()
        check(router.cover == .studio && router.sheet == nil && router.pending == nil,
              "studio opens after dismissal completes")
        router.didPresent(.studio)
        router.present(.onboarding)
        router.present(.settings)
        check(router.pending == .settings && router.cover == nil,
              "latest request wins during dismissal")
        router.didDismiss()
        check(router.sheet == .settings && router.cover == nil,
              "queued sheet cannot overlap a cover")
        router.didPresent(.settings)
        router.present(.settings)
        check(router.pending == nil && router.sheet == .settings,
              "reselecting the presented destination does not dismiss it")
        router.sheet = nil
        router.present(.studio)
        check(router.pending == .studio && router.cover == nil,
              "interactive dismissal still serializes the next presentation")
        router.dismiss()
        check(router.presented == .settings && router.pending == nil,
              "canceling during dismissal retains the outgoing modal until its callback")
        router.didDismiss()
        check(router.visible == nil && router.pending == nil && router.cover == nil,
              "canceling a pending route cannot reopen a dismissed screen")
        router.present(.onboarding)
        check(router.cover == .onboarding && router.sheet == nil, "onboarding opens alone")
        router.didPresent(.onboarding)
        router.cover = nil
        router.didDismiss()
        check(router.visible == nil && router.presented == nil,
              "interactive cover dismissal clears route ownership")
        router.present(.studio)
        router.didPresent(.studio)
        router.dismiss()
        check(router.cover == nil && router.presented == .studio,
              "programmatic dismissal waits for an appeared cover to finish")
        router.didDismiss()
        check(router.visible == nil && router.presented == nil && router.pending == nil,
              "normal programmatic dismissal leaves no active or queued route")
        router.present(.settings)
        router.didPresent(.settings)
        router.sheet = nil
        router.present(.settings)
        check(router.pending == .settings && router.sheet == nil,
              "reopening an interactively closing sheet waits for dismissal")
        router.didDismiss()
        check(router.sheet == .settings && router.pending == nil && router.presented == nil,
              "the closing sheet can reopen without overlapping its predecessor")
        let share = HomeRouter()
        share.present(.studio); share.didPresent(.studio)
        share.present(.video)
        check(share.cover == nil && share.pending == .video, "video handoff dismisses Studio before presenting")
        share.didDismiss()
        check(share.cover == .video && share.sheet == nil, "video handoff presents one canonical editor")
        share.didPresent(.video); share.present(.video)
        check(share.cover == .video && share.pending == nil, "another video handoff reuses the visible editor")
        share.dismiss(); share.didDismiss()
        check(share.visible == nil && share.cover == nil, "video Done returns to the home without a nested sheet")
        let failed = checks.filter { !($0["passed"] as! Bool) }.count
        let result: [String: Any] = ["suite": "HomeRouter", "passed": checks.count - failed,
                                     "failed": failed, "checks": checks]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        if failed > 0 { exit(1) }
    }
}
