import Foundation
import Observation
import SwiftData

/// Why there is no snapshot to show. Every case is a sentence a screen can
/// say out loud; none of them is ever rendered as `$0`.
enum EarningsUnavailable: Error, Equatable, Sendable {
    /// The shared SwiftData store would not open, so this process cannot
    /// read shifts at all (`SharedModelContainer.openingFailed`).
    case storeUnavailable
    /// A fetch threw. `detail` is for the debug sheet and the log, never for
    /// a headline.
    case fetchFailed(detail: String)
    /// The inputs could not be canonically fingerprinted, so any snapshot
    /// built from them would carry a digest no other consumer could compare
    /// (`InputManifest.ValidationError`). Refusing is the honest answer.
    case inputsInvalid(detail: String)
    /// Zero `ShiftRecord`s next to legacy rows on an account whose shifts
    /// are authoritative: the local cache was purged, not emptied. See
    /// `EarningsStore.shiftCacheWipeDetected`.
    case shiftCacheWiped

    /// What a screen may show. No currency, ever.
    var message: String {
        switch self {
        case .storeUnavailable:
            return "Payday couldn't open your shifts."
        case .fetchFailed:
            return "Payday couldn't read your shifts right now."
        case .inputsInvalid:
            return "Payday couldn't read your shifts right now."
        case .shiftCacheWiped:
            return "Payday is restoring your shifts from the server."
        }
    }
}

/// One fetch of everything a snapshot needs, plus the two facts the store
/// uses to decide whether an empty result is real.
struct EarningsFetch: Sendable {
    var inputs: EarningsInputs
    /// Legacy `TipEntry` rows present. A SwiftData entity purge takes
    /// `ShiftRecord` rows and leaves these, which is the shape of a
    /// downgrade rather than of a new account.
    var legacyTipEntryCount: Int
}

/// Where the store reads its inputs. A protocol so the tests can fail a
/// fetch, stall a fetch, or hand over fixtures without a store file.
///
/// A source that already knows WHICH kind of unavailability it hit throws
/// `EarningsUnavailable` and the store publishes it verbatim; anything else
/// becomes `.fetchFailed`. That is what keeps `.storeUnavailable` from
/// being a case nothing can produce.
@MainActor
protocol EarningsInputSource: AnyObject {
    func fetchInputs() throws -> EarningsFetch
}

extension EarningsUnavailable {
    /// This error as a published reason: a source's own
    /// `EarningsUnavailable` verbatim, anything else as `.fetchFailed`.
    static func reason(for error: Error) -> EarningsUnavailable {
        (error as? EarningsUnavailable) ?? .fetchFailed(detail: "\(error)")
    }
}

/// Owns the current `EarningsSnapshot` for this process and rebuilds it when
/// an input changes.
///
/// Injected once in `PaydayApp` via `.environment`, so every screen reads the
/// SAME snapshot and two surfaces cannot disagree about the same fact
/// (Design 2). PR 5 migrates the screens onto it; PR 4 only makes it exist,
/// correct and observable.
///
/// ## The pipeline, and the rule that makes it safe
///
/// A trigger fires, a 50 ms debounce coalesces the burst, `generation`
/// increments on the main actor, the fetch and the adapt happen on the main
/// actor (SwiftData models are not `Sendable`), the manifest is computed, an
/// unchanged digest skips the rest, and only then does a detached task value
/// the shifts. Before publishing, `guard g == generation`.
///
/// That guard is the whole point: a slow rebuild started before a fast one
/// can NEVER overwrite the newer answer, which is how a stale total gets
/// shown next to a fresh one. `EarningsStoreTests
/// .aStaleGenerationIsDropped` injects a slow builder and proves it.
@MainActor
@Observable
final class EarningsStore {
    enum State: Equatable {
        /// Before the first rebuild finishes. Not "zero".
        case loading
        /// `isRefreshing` is true while a newer rebuild is in flight; the
        /// snapshot in hand stays on screen meanwhile.
        case ready(EarningsSnapshot, isRefreshing: Bool)
        /// `last` is the most recent good snapshot, kept so a transient
        /// failure does not blank a screen that was already showing real
        /// numbers.
        case unavailable(EarningsUnavailable, last: EarningsSnapshot?)
    }

    /// Why a rebuild was asked for. Diagnostic only: every reason runs the
    /// same pipeline.
    enum Reason: String, Sendable {
        case initial
        case modelContextDidSave
        case settingsClockDidChange
        case policiesDidChange
        case calendarDayChanged
        case sceneActive
        case syncCompleted
        case manual
    }

    /// Posted when a fetch finds the wiped-cache shape. The sync leg
    /// observes it (PR 2 slice S8) and forces a server baseline.
    ///
    /// Deliberately a notification and NOT a durable flag of its own. The
    /// durable home for "this cache needs a baseline" is the sync
    /// checkpoint, whose one reader is
    /// `PaydaySyncState.shiftCacheRequiresBaseline` (design 7.4, and
    /// `design-lint.sh` rule 17 allows that function exactly one
    /// definition). A second durable copy here is the mistake slice S1 made
    /// and had to undo: the reader consults one copy while the sync leg
    /// clears the other.
    static let shiftCacheWipeDetected = Notification.Name("com.szakacsmedia.payday.shiftCacheWipeDetected")

    /// 50 ms, per Design 2. One save can fire `ModelContext.didSave`, the
    /// settings clock and the policy store within microseconds of each
    /// other; without this the store would value every shift three times
    /// for one edit.
    static let debounceNanoseconds: UInt64 = 50_000_000

    private(set) var state: State = .loading

    /// The snapshot in hand, whatever the state. Nil only before the first
    /// successful build.
    var snapshot: EarningsSnapshot? {
        switch state {
        case .loading: return nil
        case .ready(let snapshot, _): return snapshot
        case .unavailable(_, let last): return last
        }
    }

    var isRefreshing: Bool {
        if case .ready(_, let refreshing) = state { return refreshing }
        return false
    }

    /// Rebuilds completed since launch, for the debug sheet and the tests.
    private(set) var publishedCount = 0
    /// Rebuilds that found an unchanged digest and published nothing.
    private(set) var skippedCount = 0

    private let source: any EarningsInputSource
    private let builder: @Sendable (EarningsInputs, UInt64) throws -> EarningsSnapshot
    private let debounceNanoseconds: UInt64
    private let shiftsAreAuthoritative: @MainActor () -> Bool
    private let requestShiftBaseline: @MainActor () -> Void

    /// Monotonic in this process. Incremented on the main actor before every
    /// build, and the published generation never goes backwards.
    private var generation: UInt64 = 0
    private var pipeline: Task<Void, Never>?
    /// The notification tokens, in a box whose own `deinit` removes them.
    /// A `deinit` on this main-actor class cannot touch isolated state, and
    /// leaving block observers registered would keep one closure per store
    /// alive in the notification center for the life of the process.
    private let observers = ObserverBox()
    /// The inputs the current snapshot was built from, for `preview(draft:)`.
    private var lastInputs: EarningsInputs?
    /// True once a wipe has been reported, so one purged cache asks for one
    /// baseline rather than one per trigger.
    private var reportedShiftCacheWipe = false

    /// - Parameters:
    ///   - shiftsAreAuthoritative: whether `ShiftRecord` is the read-
    ///     authoritative representation for this account. Defaults to
    ///     `false` because PR 2's conversion (slice S7) has not landed:
    ///     until it does, an account with zero shifts and legacy rows is
    ///     simply pre-conversion, NOT a wiped cache, and treating it as one
    ///     would blank every screen for every existing user. S7 passes its
    ///     single `shiftsAreAuthoritative` in here.
    ///   - requestShiftBaseline: what to do about a wiped cache. Defaults to
    ///     posting `shiftCacheWipeDetected`.
    init(
        source: any EarningsInputSource,
        builder: @escaping @Sendable (EarningsInputs, UInt64) throws -> EarningsSnapshot = {
            try EarningsSnapshot.build($0, generation: $1)
        },
        debounceNanoseconds: UInt64 = EarningsStore.debounceNanoseconds,
        shiftsAreAuthoritative: @MainActor @escaping () -> Bool = { false },
        requestShiftBaseline: @MainActor @escaping () -> Void = {
            NotificationCenter.default.post(name: EarningsStore.shiftCacheWipeDetected, object: nil)
        },
        observesTriggers: Bool = true
    ) {
        self.source = source
        self.builder = builder
        self.debounceNanoseconds = debounceNanoseconds
        self.shiftsAreAuthoritative = shiftsAreAuthoritative
        self.requestShiftBaseline = requestShiftBaseline
        if observesTriggers {
            startObserving()
        }
    }

    // MARK: - Triggers

    /// Every input change that can move a number, per Design 2. Scene
    /// `.active` is NOT here: `UIApplication` is unavailable to an app
    /// extension and this type compiles into the widget, so `PaydayApp`
    /// calls `requestRebuild(reason: .sceneActive)` from `.onChange(of:
    /// scenePhase)` instead.
    ///
    /// `nonisolated` and internal, not private, for one reason: a wave-1 PR 5
    /// screen that still builds its own `LegacySnapshotBridge` snapshot has to
    /// know when to build the next one, and the answer must be THIS list and
    /// not a second copy of it. `LegacySnapshotRevision` merges exactly these
    /// publishers. When PR 2 slice S7 lands and the screens read
    /// `earningsStore.snapshot` directly, that consumer goes away and this can
    /// go back to private.
    nonisolated static let triggerNames: [(Notification.Name, Reason)] = [
        (ModelContext.didSave, .modelContextDidSave),
        (PaydaySettingsSyncClock.didChange, .settingsClockDidChange),
        (PolicyStore.didChange, .policiesDidChange),
        (.NSCalendarDayChanged, .calendarDayChanged),
    ]

    private func startObserving() {
        for (name, reason) in Self.triggerNames {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // `queue: .main` runs this block on the main thread, which
                // is what makes the assumption true rather than hopeful.
                MainActor.assumeIsolated {
                    self?.requestRebuild(reason: reason)
                }
            }
            observers.add(observer)
        }
    }

    // MARK: - Rebuilding

    /// Coalesces into one rebuild. Safe to call from a view body's
    /// `.onAppear`, a notification, or a test.
    func requestRebuild(reason: Reason = .manual) {
        if case .ready(let snapshot, false) = state {
            state = .ready(snapshot, isRefreshing: true)
        }
        pipeline?.cancel()
        pipeline = Task { [weak self] in
            if let nanoseconds = self?.debounceNanoseconds, nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
                if Task.isCancelled { return }
            }
            await self?.rebuild(reason: reason)
        }
    }

    /// Runs the whole pipeline and waits for it. Tests and `buildOnce`-style
    /// callers use this; the app uses `requestRebuild`.
    func rebuildNow(reason: Reason = .manual) async {
        pipeline?.cancel()
        await rebuild(reason: reason)
    }

    private func rebuild(reason: Reason) async {
        generation += 1
        let g = generation

        // Fetch and adapt on the main actor: SwiftData models are not
        // Sendable, so this is the last point a `ShiftRecord` is touched.
        let fetch: EarningsFetch
        do {
            fetch = try source.fetchInputs()
        } catch {
            publish(.unavailable(.reason(for: error), last: snapshot), generation: g)
            return
        }

        // A purged cache is not an empty account. Publishing zeros here is
        // the worst available answer: it looks exactly like "you earned
        // nothing", and the device may never derive a shift to repair it.
        if shiftsAreAuthoritative(), fetch.inputs.shifts.isEmpty, fetch.legacyTipEntryCount > 0 {
            if !reportedShiftCacheWipe {
                reportedShiftCacheWipe = true
                requestShiftBaseline()
            }
            publish(.unavailable(.shiftCacheWiped, last: snapshot), generation: g)
            return
        }
        reportedShiftCacheWipe = false

        let inputs = fetch.inputs
        let manifest: InputManifest
        do {
            manifest = try inputs.manifest()
        } catch {
            publish(.unavailable(.inputsInvalid(detail: "\(error)"), last: snapshot), generation: g)
            return
        }

        // Nothing that can change a number has changed. The digest covers
        // asOf too (it is hashed into the canonical text), so one comparison
        // answers both halves of Design 2's "digest and asOf unchanged".
        if case .ready(let current, _) = state, current.stamp.digest == manifest.digest {
            guard g == generation else { return }
            skippedCount += 1
            state = .ready(current, isRefreshing: false)
            return
        }

        let build = builder
        let result: Result<EarningsSnapshot, Error> = await Task.detached(priority: .userInitiated) {
            do {
                return .success(try build(inputs, g))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let snapshot):
            guard g == generation else { return }
            lastInputs = inputs
            publish(.ready(snapshot, isRefreshing: false), generation: g)
        case .failure(let error):
            publish(.unavailable(.inputsInvalid(detail: "\(error)"), last: snapshot), generation: g)
        }
    }

    /// The one writer of `state`, and the one place the generation guard is
    /// applied. An older computation returning late is dropped here.
    private func publish(_ next: State, generation g: UInt64) {
        guard g == generation else { return }
        state = next
        if case .ready = next { publishedCount += 1 }
    }

    // MARK: - Preview

    /// What the snapshot would say if `draft` were saved, without publishing
    /// anything.
    ///
    /// Valued through the same ledger over the same inputs, so a sheet
    /// saying "this takes today to $X" cannot quote a number the committed
    /// shift would not produce. Nil before the first successful build, when
    /// there is nothing to substitute into.
    func preview(draft: ShiftInput) -> EarningsSnapshot? {
        guard let lastInputs else { return nil }
        return try? builder(lastInputs.substituting(draft), generation)
    }

    // MARK: - Out of process

    /// One snapshot, no observation, no publishing: the widget and
    /// `PeriodTotalIntent` recompute rather than read a file.
    ///
    /// An app-written file would go stale by construction, because App
    /// Intents and Controls already write to the shared store from other
    /// processes (Design 2, "Out-of-process: recompute, do not read a file").
    /// - Parameter shiftsAreAuthoritative: same meaning and same default as
    ///   on `init`. It is a parameter rather than an omission so the widget
    ///   and the intent cannot end up with a different rule from the app:
    ///   a Lock Screen reading `$0` off a purged cache would be the same
    ///   lie in a smaller font.
    static func buildOnce(
        source: any EarningsInputSource,
        computedAt: Date = Date(),
        shiftsAreAuthoritative: Bool = false
    ) -> Result<EarningsSnapshot, EarningsUnavailable> {
        let fetch: EarningsFetch
        do {
            fetch = try source.fetchInputs()
        } catch {
            return .failure(.reason(for: error))
        }
        if shiftsAreAuthoritative, fetch.inputs.shifts.isEmpty, fetch.legacyTipEntryCount > 0 {
            return .failure(.shiftCacheWiped)
        }
        do {
            return .success(try EarningsSnapshot.build(
                fetch.inputs,
                generation: 0,
                computedAt: computedAt
            ))
        } catch {
            return .failure(.inputsInvalid(detail: "\(error)"))
        }
    }
}

/// Holds notification tokens and unregisters them when it is released.
private final class ObserverBox: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []
    private let lock = NSLock()

    func add(_ token: NSObjectProtocol) {
        lock.withLock { tokens.append(token) }
    }

    deinit {
        for token in lock.withLock({ tokens }) {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

/// The production input source: the shared SwiftData store plus the two
/// configuration stores.
@MainActor
final class ModelContextEarningsInputSource: EarningsInputSource {
    private let makeContext: () -> ModelContext
    private let policies: () -> CompensationPolicies
    private let schedule: () -> PaySchedule?
    private let now: () -> Date
    private let storeOpened: Bool

    /// The app's spelling: the shared container, the live `PolicyStore` and
    /// the live `PayScheduleStore`.
    ///
    /// A FRESH `ModelContext` per fetch, deliberately. A long-lived context
    /// answers from its own registered objects, so one held across rebuilds
    /// can hand back a row that another context (a view's, an App Intent's,
    /// the sync leg's) has since changed — and a snapshot built from a stale
    /// row is exactly the class of disagreement this whole PR exists to
    /// remove. A context is cheap next to valuing every shift.
    init(
        container: ModelContainer,
        policyStore: PolicyStore,
        scheduleStore: PayScheduleStore,
        now: @escaping () -> Date = { Date() },
        storeOpened: Bool = !SharedModelContainer.openingFailed
    ) {
        self.makeContext = { ModelContext(container) }
        self.policies = { policyStore.policies }
        self.schedule = { scheduleStore.schedule }
        self.now = now
        self.storeOpened = storeOpened
    }

    /// The test seam: an explicit context (reused, so a test can insert and
    /// read in one place) and explicit policies, schedule and clock.
    init(
        context: ModelContext,
        policies: @escaping () -> CompensationPolicies,
        schedule: @escaping () -> PaySchedule?,
        now: @escaping () -> Date = { Date() },
        storeOpened: Bool = true
    ) {
        self.makeContext = { context }
        self.policies = policies
        self.schedule = schedule
        self.now = now
        self.storeOpened = storeOpened
    }

    func fetchInputs() throws -> EarningsFetch {
        // The shared store fell back to memory, so this process cannot read
        // shifts at all. Named rather than generic, because the app shows
        // its own recovery screen for it.
        guard storeOpened else { throw EarningsUnavailable.storeUnavailable }

        let policies = policies()
        // The FROZEN payroll zone. `TimeZone.current` appears nowhere in
        // this file: a device that travels must not move a shift into
        // another week or another pay period.
        let zone = policies.payrollTimeZone ?? .current

        let context = makeContext()
        let shifts = try context.fetch(FetchDescriptor<ShiftRecord>())
        let paychecks = try context.fetch(FetchDescriptor<PaycheckRecord>())
        let legacyCount = try context.fetchCount(FetchDescriptor<TipEntry>())

        let adapted = ShiftInputAdapter.adapt(shifts, calendars: policies.calendars)

        return EarningsFetch(
            inputs: EarningsInputs(
                shifts: adapted.inputs,
                paychecks: PaycheckInputAdapter.inputs(from: paychecks, payrollTimeZone: zone),
                schedule: schedule().map { scheduleInput($0, zone: zone) },
                rates: policies.rates,
                calendars: policies.calendars,
                asOf: CivilDay(now(), in: zone),
                unreadableReceiptShiftIDs: adapted.unreadableReceiptShiftIDs
            ),
            legacyTipEntryCount: legacyCount
        )
    }

    private func scheduleInput(_ schedule: PaySchedule, zone: TimeZone) -> PayScheduleInput {
        PayScheduleInput(
            frequency: schedule.frequency.rawValue,
            anchorPeriodEnd: CivilDay(schedule.anchorPeriodEnd, in: zone),
            payDelayDays: schedule.resolvedPayDelayDays,
            // The RAW value, not `resolvedFirstWeekday`: resolving consults
            // `Calendar.current`, which would make the manifest digest
            // depend on the device's locale and stop two devices holding the
            // same data from agreeing on the same fingerprint.
            firstWeekday: schedule.firstWeekday
        )
    }
}
