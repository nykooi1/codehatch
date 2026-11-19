import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

/// Made-up sessions shown in place of your own, for demos and screen recordings. Nothing here is read from disk,
/// and clicking a sample session does not open or close anything.
enum Demo {
    /// Set by the drawing tests, which want sample sessions without changing anyone's saved setting.
    static var forced = false
    /// The sample session you last went to, which then counts as the one you are in.
    static var here: String?
    static var on: Bool { forced || Prefs.bool("demoMode") }
    static var hidden = Set<String>()
    //                 id, repo, title, status, seconds ago, branch, last message, recap, waiting for
    static let rows: [(String, String, String, String, Double, String, String, String, String?)] = [
        ("d2", "storefront", "Speed up the product search page", "waiting", 40, "perf/search-page", "try caching the facet counts", "The facet counts were the slow part. A cache for them is written and the page loads in a third of the time; it needs your OK to run the benchmark.", "permission"),
        ("d1", "storefront", "Checkout fails for saved cards", "busy", 134, "fix/saved-card-checkout", "go ahead and run the migration", "Found the cause: the saved-card token is read before it is refreshed. Running the database migration now.", nil),
        ("d3", "storefront", "Holiday banner and countdown", "idle", 190, "feature/holiday-banner", "looks good, make the countdown end at midnight local time", "The banner and countdown are done and match the design. Next: you review it on a phone-sized screen.", nil),
        ("d4", "ios-app", "Push notifications arrive twice", "busy", 61, "bugfix/duplicate-push", "check whether both the old and new token are registered", "Reproduced the duplicate. Checking whether the device is registered under two tokens.", nil),
        ("d5", "ios-app", "Onboarding screens redesign", "idle", 3_100, "feature/onboarding-v2", "use the larger illustration on the second screen", "Three of the four screens are rebuilt. The last one is waiting on the final copy.", nil),
        ("d6", "api-server", "Rate limit the export endpoint", "idle", 9_400, "feature/export-rate-limit", "100 a minute per account is fine", "Rate limiting is in and covered by tests. Next: decide the limit for enterprise accounts.", nil),
        ("d7", "api-server", "Upgrade to the new Postgres driver", "idle", 97_000, "chore/pg-driver", "hold off until after the release", "Paused. The upgrade works locally; two integration tests still fail on connection pooling.", nil),
        ("d8", "docs-site", "Rewrite the getting-started guide", "idle", 20_000, "docs/getting-started", "shorter, and lead with the install command", "First draft is written. Next: you read it through for tone.", nil),
    ]
    // Recently closed sample sessions: id, repo, title, seconds since, branch, what you last asked, where it got to.
    static let closedRows: [(String, String, String, Double, String, String, String)] = [
        ("3f2a9c1e-7b4d-4e8a-9c21-5d6e7f8a9b01", "storefront", "Fix the cart badge count", 2_400, "fix/cart-badge", "ship it",
         "The badge now counts items rather than lines, and updates as soon as something is added. Merged."),
        ("8b1c2d3e-4f5a-4b6c-8d7e-9f0a1b2c3d02", "api-server", "Webhook retries with backoff", 9_000, "feature/webhook-retries", "add a test for the fifth retry",
         "Failed webhooks are retried up to five times, waiting longer each time. The test for the fifth retry is the last thing open."),
        ("c4d5e6f7-a8b9-4c0d-9e1f-2a3b4c5d6e03", "ios-app", "Dark mode for settings", 18_000, "feature/settings-dark-mode", "the toggles are too dim",
         "Settings follow the system's dark mode. The toggles are brighter; the last thing to check is the colour of the section headers."),
        ("d7e8f9a0-b1c2-4d3e-8f4a-5b6c7d8e9f04", "storefront", "Faster product images", 30_000, "perf/product-images", "use the smaller sizes on phones",
         "Product images load in the size each screen needs. Phones now download about a third as much."),
        ("e1f2a3b4-c5d6-4e7f-9a8b-0c1d2e3f4a05", "api-server", "Rotate the signing keys", 64_000, "chore/rotate-keys", "keep the old key valid for a day",
         "New keys are in use. The old one is still accepted until tomorrow, then it can be removed."),
        ("f5a6b7c8-d9e0-4f1a-8b2c-3d4e5f6a7b06", "docs-site", "Broken links in the API reference", 150_000, "fix/api-ref-links", "run the link checker again",
         "Fixed 14 broken links. The link checker now runs on every change, so new ones are caught before they go live."),
        ("a9b0c1d2-e3f4-4a5b-9c6d-7e8f9a0b1c07", "ios-app", "Pull to refresh on the orders screen", 240_000, "feature/orders-refresh", "add the little haptic when it lets go",
         "Pulling down on the orders screen refreshes it, with a light tap of feedback as it lets go."),
    ]
    static func sessions() -> [Session] {
        let now = Date().timeIntervalSince1970
        return rows.filter { !hidden.contains($0.0) }.map { r in
            var s = Session(id: r.0, pid: 0, cwd: "/Projects/" + r.1, status: r.3, updatedAt: (now - r.4) * 1000, title: r.2)
            s.branch = r.5; s.lastAsked = r.6; s.recap = r.7; s.waitingFor = r.8
            if r.3 == "busy" { Busy.since[r.0] = Busy.since[r.0] ?? now - r.4 }
            return s
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    static func closed() -> [Session] {
        let now = Date().timeIntervalSince1970
        return closedRows.map { r in
            // Its folder: the matching made-up project in ~/codehatch-demo if there is one, so resuming it for a recording
            // lands somewhere real.
            let demo = NSHomeDirectory() + "/codehatch-demo/" + r.1
            var s = Session(id: r.0, pid: 0, cwd: FileManager.default.fileExists(atPath: demo) ? demo : "/Projects/" + r.1, status: "closed", updatedAt: (now - r.3) * 1000, title: r.2)
            s.branch = r.4; s.lastAsked = r.5; s.recap = r.6
            return s
        }
    }
}
