import EventKit

// One access request for the whole app. A board can hold three calendar tiles,
// and each used to request access on its own: the system would show a prompt,
// and while it was up, more requests would come in — the result depended on
// which one got answered last.
//
// Second important point: writeOnly ("add only") is NOT the user declining —
// it's the default state. Since macOS 14, apps get event-creation rights
// implicitly, with no prompt at all, and the status is already 4 even if the
// person was never asked anything. So full access has to be requested even from
// writeOnly, otherwise the prompt never shows and the app never appears in
// System Settings. But we only ask once per launch: asking again on every tile
// activation would just stack prompt on prompt, which we've already been through.
@MainActor
enum CalendarAccess {
    /// One store for the whole app. Three calendar tiles used to each open
    /// their own connection to CalendarAgent and their own change subscription
    /// for the same data
    static let store = EKEventStore()

    private static var pending: [EKEntityType: Task<Void, Never>] = [:]
    private static var asked: Set<EKEntityType> = []

    static func status(_ type: EKEntityType) -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: type)
    }

    /// Can we still show the system prompt — the empty-state view uses this to
    /// decide what to offer
    static func canAsk(_ type: EKEntityType) -> Bool {
        guard !asked.contains(type) else { return false }
        let current = status(type)
        return current == .notDetermined || current == .writeOnly
    }

    /// Ask when the empty-state button is pressed: we may have already asked this
    /// launch, but the person tapped it themselves — so a prompt is warranted
    static func ask(_ type: EKEntityType, store: EKEventStore) async -> EKAuthorizationStatus {
        asked.remove(type)
        return await ensure(type, store: store)
    }

    /// Requests access if not already requested, and returns the resulting status
    static func ensure(_ type: EKEntityType, store: EKEventStore) async -> EKAuthorizationStatus {
        let current = status(type)
        let canAsk = current == .notDetermined || current == .writeOnly
        guard canAsk, !asked.contains(type) else { return current }
        // Wait for someone else's in-flight request BEFORE marking this type as
        // asked: otherwise a second tile would read a stale status without
        // waiting for the prompt's answer
        if let existing = pending[type] {
            await existing.value
            return status(type)
        }
        asked.insert(type)
        let task = Task { @MainActor in
            switch type {
            case .event: _ = try? await store.requestFullAccessToEvents()
            default: _ = try? await store.requestFullAccessToReminders()
            }
        }
        pending[type] = task
        await task.value
        pending[type] = nil
        return status(type)
    }
}
