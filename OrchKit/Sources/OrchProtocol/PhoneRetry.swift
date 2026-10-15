import Foundation

/// Retry classes of host section 11A.14 14.4 (the table is authoritative, amendment C). Only C and D are definite.
public enum PhoneRetryClass: String, Sendable, Equatable, CaseIterable {
    /// Not run: resend the same idem and the same signed bytes (a new rid and seq where the protocol needs them).
    case a
    /// Unknown: same idem only; resolve with `outcome.get`, then by a log read. Never re-sign.
    case b
    /// Definite, zero landed; a new signature may skip the review when the auto re-sign conditions hold.
    case cAuto
    /// Definite, zero landed; a new review first.
    case cReview
    /// Terminal or landed: never re-sign for this review. An unknown code is D.
    case d

    /// `retryable` on a relay answer is derived from the class: A and B true, C and D false (amendment C).
    public var retryable: Bool { self == .a || self == .b }
    public var isDefinite: Bool { self == .cAuto || self == .cReview || self == .d }
}

/// Facts a few codes need (14.4 "Placements it fixes").
public struct PhoneRefusalContext: Equatable, Sendable {
    /// The event id the answer is about (its ULID time bounds `outcome.unknown_idem`).
    public let eventID: String
    /// The phone's best estimate of host time now, in ms (`local + adopted offset`).
    public let hostNowMs: Int64
    /// `internal` after admission, where effects are possible.
    public let admitted: Bool
    /// The result of a log read after the bound: `true` event absent, `false` event present, `nil` not read yet.
    public let logShowsEventAbsent: Bool?

    public init(eventID: String, hostNowMs: Int64, admitted: Bool = false, logShowsEventAbsent: Bool? = nil) {
        self.eventID = eventID; self.hostNowMs = hostNowMs; self.admitted = admitted; self.logShowsEventAbsent = logShowsEventAbsent
    }
}

public enum PhoneRetryTable {
    /// ULID time + 900 s (host window) + 300 s (skew): after it an unknown idem is definite.
    public static let unknownIdemBoundMs: Int64 = 1_200_000

    static let classA: Set<String> = [
        "stale_epoch", "stale_timestamp", "stale_sequence", "no_answer", "silence",
        "timeout", "cancelled", "store.busy", "lock.busy", "busy", "rate.limited", "quota.host", "host.restarting", "conn.overloaded",
        "outcome.unknown",
    ]
    static let classB: Set<String> = ["already_done.unknown", "rid_conflict", "outcome.pending", "pending", "idem.expired"]
    static let classCAuto: Set<String> = ["members.stale", "ticket.key_not_next"]
    static let classCReview: Set<String> = ["event.bad_base", "question.stale", "event.expired", "event.abandoned"]
    static let classD: Set<String> = [
        "committed", "failed.landed",
        "question.answered", "question.unknown", "answer.not_allowed", "answer.bad_option",
        "role.denied", "member.unknown", "device.scope", "device.invalid", "device.unknown", "ticket.frozen", "freeze.active",
        "ticket.not_visible", "not_found",
        "ticket.exists", "ticket.bad_reference", "event.duplicate_id",
        "forbidden_scope", "op.not_allowed", "sig.invalid", "validation.event", "validation.text", "invalid.input", "idem.conflict",
        "idem.required",
    ]

    /// Every code the table names (the shared-data-file check of 14.4 will compare against core's emitted codes).
    public static var knownCodes: Set<String> {
        classA.union(classB).union(classCAuto).union(classCReview).union(classD).union(["outcome.unknown_idem", "internal"])
    }

    /// Maps a code to its class. Codes are compared byte-exactly; an unknown code is D.
    public static func classify(_ code: String, _ ctx: PhoneRefusalContext) -> PhoneRetryClass {
        func has(_ set: Set<String>) -> Bool { set.contains { $0.bytesEqual(code) } }
        if code.bytesEqual("outcome.unknown_idem") {
            // an event id the phone cannot parse has no bound to wait for: D, never an unbounded retry
            guard let t = ULID.timeMs(of: ctx.eventID) else { return .d }
            guard ctx.hostNowMs >= saturatingAdd(t, unknownIdemBoundMs) else { return .b }
            switch ctx.logShowsEventAbsent {
            case .some(true): return .cReview
            case .some(false): return .d   // the event is in the log: landed
            case .none: return .b          // after the bound, but still to be resolved by a log read
            }
        }
        // internal: D, except after admission where effects are possible: B
        if code.bytesEqual("internal") { return ctx.admitted ? .b : .d }
        if has(classA) { return .a }
        if has(classB) { return .b }
        if has(classCAuto) { return .cAuto }
        if has(classCReview) { return .cReview }
        return .d
    }
}

/// What the sign sheet displayed for an answer: the recomputed `qid` and `hash`, the option or text, and the unbound context
/// (`to`, `why`, `recommended`, `blocking`) which the auto re-sign compares too, stricter than the hash (14.4 item 2). Public code can
/// only build one from an `F1Question.Reviewed` (a snapshot whose hash the phone reproduced). Strings compare byte-exactly.
public struct AnswerDisplay: Equatable, Sendable {
    public let qid: String, hash: String
    public let option: String?, text: String?
    public let to: [String]
    public let why: String?, recommended: String?
    public let blocking: Bool
    init(qid: String, hash: String, option: String?, text: String?, to: [String], why: String?, recommended: String?, blocking: Bool) {
        self.qid = qid; self.hash = hash; self.option = option; self.text = text; self.to = to
        self.why = why; self.recommended = recommended; self.blocking = blocking
    }
    public init(_ r: F1Question.Reviewed, option: String?, text: PhoneEvents.PreparedText?) throws {
        if let option, !r.question.options.contains(where: { $0.key.bytesEqual(option) }) { throw PhoneEvents.Failure.unknownOption }
        self.init(qid: r.qid, hash: r.hash, option: option, text: text?.value, to: r.question.to, why: r.question.why,
                  recommended: r.question.recommended, blocking: r.question.blocking)
    }
    public static func == (a: AnswerDisplay, b: AnswerDisplay) -> Bool {
        a.qid.bytesEqual(b.qid) && a.hash.bytesEqual(b.hash) && bytesEqual(a.option, b.option) && bytesEqual(a.text, b.text)
            && a.to.count == b.to.count && zip(a.to, b.to).allSatisfy { $0.bytesEqual($1) }
            && bytesEqual(a.why, b.why) && bytesEqual(a.recommended, b.recommended) && a.blocking == b.blocking
    }
}

func bytesEqual(_ a: String?, _ b: String?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (let x?, let y?): return x.bytesEqual(y)
    default: return false
    }
}

public struct CreationDisplay: Equatable, Sendable {
    public let ticketType: String, title: String, owner: String
    /// From the fresh `workspace.show` and the phone's own certificate; the title is the prepared text that was reviewed.
    package init(ticketType: String, title: PhoneEvents.PreparedText, owner: String) { self.ticketType = ticketType; self.title = title.value; self.owner = owner }
    init(ticketType: String, title: String, owner: String) { self.ticketType = ticketType; self.title = title; self.owner = owner }
    public static func == (a: CreationDisplay, b: CreationDisplay) -> Bool {
        a.ticketType.bytesEqual(b.ticketType) && a.title.bytesEqual(b.title) && a.owner.bytesEqual(b.owner)
    }
}

public enum ReviewDisplay: Equatable, Sendable {
    case answer(AnswerDisplay)
    case creation(CreationDisplay)
}

public struct AutoResignInput: Sendable {
    public var lastClass: PhoneRetryClass
    /// The last host answer was state `refused` for that exact idem (a stored refusal, not `failed` with landed events).
    public var lastAnswerWasRefusedForExactIdem: Bool
    /// An earlier idem of the same review is unresolved (class A or B).
    public var earlierIdemUnresolved: Bool
    public var reviewed: ReviewDisplay
    /// One fresh `ticket.get` snapshot (plus `workspace.show` for a creation), mapped to the same display shape.
    public var fresh: ReviewDisplay
    /// The last signed event, and the unsigned event the phone would sign now.
    public var previous: [String: JSONValue]
    public var proposed: [String: JSONValue]
    /// Log of the previous and proposed event (a creation keeps its reviewed uid).
    public var previousLog: String
    public var proposedLog: String
    /// A creation's sign sheet said beforehand "the key is assigned when sent".
    public var keyAssignedDisclosed: Bool
    public var foregroundAndUnlockedSinceTap: Bool
    /// Auto re-signs already done for this review (key races included).
    public var autoResignsSoFar: Int

    public init(lastClass: PhoneRetryClass, lastAnswerWasRefusedForExactIdem: Bool, earlierIdemUnresolved: Bool, reviewed: ReviewDisplay,
                fresh: ReviewDisplay, previous: [String: JSONValue], proposed: [String: JSONValue], previousLog: String,
                proposedLog: String, keyAssignedDisclosed: Bool, foregroundAndUnlockedSinceTap: Bool, autoResignsSoFar: Int) {
        self.lastClass = lastClass; self.lastAnswerWasRefusedForExactIdem = lastAnswerWasRefusedForExactIdem
        self.earlierIdemUnresolved = earlierIdemUnresolved; self.reviewed = reviewed; self.fresh = fresh
        self.previous = previous; self.proposed = proposed; self.previousLog = previousLog; self.proposedLog = proposedLog
        self.keyAssignedDisclosed = keyAssignedDisclosed; self.foregroundAndUnlockedSinceTap = foregroundAndUnlockedSinceTap
        self.autoResignsSoFar = autoResignsSoFar
    }
}

public enum AutoResign {
    public static let maxPerReview = 3

    public enum Decision: Equatable, Sendable {
        case allow
        case deny(Reason)
    }
    public enum Reason: Equatable, Sendable {
        case notCAuto, notRefusedForExactIdem, earlierIdemUnresolved
        case displayedFieldChanged
        case unexpectedFieldChanged(String)
        case logChanged
        case keyDisclosureMissing
        case notForegroundUnlocked
        case limitReached
    }

    /// Host section 11A.14 14.4 "Auto re-sign (no new review), only when all hold" (items 1 to 6). Pure: the first failing
    /// condition in the spec's order is returned.
    public static func decide(_ i: AutoResignInput) -> Decision {
        guard i.lastClass == .cAuto else { return .deny(.notCAuto) }
        guard i.lastAnswerWasRefusedForExactIdem else { return .deny(.notRefusedForExactIdem) }
        guard !i.earlierIdemUnresolved else { return .deny(.earlierIdemUnresolved) }
        guard i.reviewed == i.fresh else { return .deny(.displayedFieldChanged) }
        let isCreation: Bool
        if case .creation = i.reviewed { isCreation = true } else { isCreation = false }
        guard i.previousLog.bytesEqual(i.proposedLog) else { return .deny(.logChanged) }
        let allowed: Set<String> = isCreation ? ["roster_v", "id", "sig", "key"] : ["roster_v", "id", "sig"]
        for k in Set(i.previous.keys).union(i.proposed.keys).sorted() where !allowed.contains(k) {
            if i.previous[k] != i.proposed[k] { return .deny(.unexpectedFieldChanged(k)) }
        }
        if isCreation && !i.keyAssignedDisclosed { return .deny(.keyDisclosureMissing) }
        guard i.foregroundAndUnlockedSinceTap else { return .deny(.notForegroundUnlocked) }
        guard i.autoResignsSoFar < maxPerReview else { return .deny(.limitReached) }
        return .allow
    }
}
