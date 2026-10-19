import AccuChekKit
import CGMBLEKit
import Combine
import EventKit
import EversenseKit
import Foundation
import G7SensorKit
import LibreLoop
import LibreTransmitter
import LoopKitUI
import OmnipodKit
import SwiftUI
import Swinject

protocol DeviceCalendarManager: AnyObject {
    var isEnabled: Bool { get set }
    /// `EKCalendar.calendarIdentifier` of the calendar the events go into.
    var calendarIdentifier: String? { get set }
    /// Minutes before each event for an alert; `nil` means no alert.
    var alertMinutesBefore: Int? { get set }
    func requestAccess() async -> Bool
    func writableCalendars() -> [EKCalendar]
    func createDedicatedCalendar() throws -> EKCalendar
    func resync()
}

/// One calendar event per device milestone. Each event is created once and then moved
/// whenever the device reports a new date (a new pod or a new sensor), so edits such as
/// a changed colour or extra alerts survive device changes.
enum DeviceCalendarEvent: String, CaseIterable, Codable {
    case podExpires
    case podStops
    case sensorExpires
    case sensorStops

    var title: String {
        switch self {
        case .podExpires: return "Pod expires"
        case .podStops: return "Pod stops insulin"
        case .sensorExpires: return "CGM sensor expires"
        case .sensorStops: return "CGM sensor stops"
        }
    }

    var notes: String {
        switch self {
        case .podExpires: return "72 h reached. Trio keeps looping for 8 more hours, then the pod stops."
        case .podStops: return "End of the 8 h grace period: the pod stops delivering insulin."
        case .sensorExpires: return "Sensor session ends. Dexcom G7 keeps reading for a 12 h grace period."
        case .sensorStops: return "End of the sensor's grace period: no more glucose readings."
        }
    }
}

final class BaseDeviceCalendarManager: DeviceCalendarManager, Injectable {
    /// Omnipod keeps delivering for 8 h after `expiresAt` (80 h service life − 72 h nominal life).
    /// OmnipodKit's `Pod.serviceDuration` is internal, so the value is repeated here.
    private static let podGracePeriod: TimeInterval = 8 * 60 * 60
    /// A pod's `expiresAt` is recomputed from pod time on every status read and drifts
    /// by seconds; only a bigger change means a new device (or a corrected date).
    private static let moveThreshold: TimeInterval = 5 * 60
    static let dedicatedCalendarTitle = "Trio Devices"

    @Injected() private var deviceDataManager: DeviceDataManager!
    @Injected() private var fetchGlucoseManager: FetchGlucoseManager!
    @Injected() private var glucoseStorage: GlucoseStorage!

    @Persisted(key: "DeviceCalendarManager.isEnabled") var isEnabled = false {
        didSet { resync() }
    }

    @Persisted(key: "DeviceCalendarManager.calendarIdentifier") var calendarIdentifier: String? = nil {
        didSet { resync() }
    }

    @Persisted(key: "DeviceCalendarManager.alertMinutesBefore") var alertMinutesBefore: Int? = 60 {
        didSet { resync() }
    }

    /// Event identifiers we created, and the device date each was last set to.
    @Persisted(key: "DeviceCalendarManager.eventIDs") private var eventIDs: [String: String] = [:]
    @Persisted(key: "DeviceCalendarManager.syncedDates") private var syncedDates: [String: Date] = [:]

    private let eventStore = EKEventStore()
    private let queue = DispatchQueue(label: "BaseDeviceCalendarManager.queue", qos: .utility)
    private var latestDates: [DeviceCalendarEvent: Date] = [:]
    private var subscriptions = Set<AnyCancellable>()

    init(resolver: Resolver) {
        injectServices(resolver)

        deviceDataManager.pumpExpiresAtDate
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshDates() }
            .store(in: &subscriptions)

        // The CGM managers expose their session dates without publishing changes,
        // so re-read them whenever a reading or a lifecycle update arrives.
        glucoseStorage.updatePublisher
            .merge(with: fetchGlucoseManager.cgmProgressHighlight.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshDates() }
            .store(in: &subscriptions)

        Foundation.NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.resync() }
            .store(in: &subscriptions)
    }

    // MARK: - Device dates

    /// Reads the current device dates on the main thread, where the device managers are used.
    private func refreshDates() {
        var dates: [DeviceCalendarEvent: Date] = [:]
        if deviceDataManager.pumpManager is OmniPumpManager, let expires = deviceDataManager.pumpExpiresAtDate.value {
            dates[.podExpires] = expires
            dates[.podStops] = expires.addingTimeInterval(Self.podGracePeriod)
        }
        let (sensorExpires, sensorStops) = Self.sensorDates(manager: fetchGlucoseManager.cgmManager)
        dates[.sensorExpires] = sensorExpires
        dates[.sensorStops] = sensorStops

        queue.async {
            self.latestDates.merge(dates) { _, new in new }
            self.syncAll()
        }
    }

    /// Mirrors `Home.StateModel.resolveSensorExpiresAt`, but keeps the G7 expiry and the end
    /// of its grace period apart instead of switching from one to the other.
    private static func sensorDates(manager: CGMManagerUI?) -> (expires: Date?, stops: Date?) {
        switch manager {
        case let g7 as G7CGMManager:
            return (g7.sensorExpiresAt, g7.sensorEndsAt)
        case let g6 as G6CGMManager:
            return (g6.latestReading?.sessionExpDate, nil)
        case let g5 as G5CGMManager:
            return (g5.latestReading?.sessionExpDate, nil)
        case let libreTransmitter as LibreTransmitterManagerV3:
            return (libreTransmitter.sensorInfoObservable.expiresAt, nil)
        case let libreLoop as LibreLoopCGMManager:
            if case let .active(remaining, _) = libreLoop.sensorLifecycle, remaining > 0 {
                // Derived from "time remaining", so it jitters; the move threshold absorbs that.
                return (Date().addingTimeInterval(remaining), nil)
            }
            return (nil, nil)
        case let eversense as EversenseCGMManager:
            return (eversense.state.expiresAt, nil)
        case let accuChek as AccuChekCgmManager:
            return (accuChek.state.cgmEndTime, nil)
        default:
            return (nil, nil)
        }
    }

    // MARK: - Calendar

    /// Asks on this manager's own store: a store created before access was granted lists no
    /// calendars or accounts until it is reset, so reset it once access is there.
    func requestAccess() async -> Bool {
        if !hasFullAccess {
            do {
                guard try await eventStore.requestFullAccessToEvents() else { return false }
            } catch {
                warning(.service, "Device calendar: access not granted", error: error)
                return false
            }
        }
        eventStore.reset()
        return true
    }

    func writableCalendars() -> [EKCalendar] {
        eventStore.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
    }

    /// Creates (or reuses) a "Trio Devices" calendar, preferring iCloud so it shows on every device.
    func createDedicatedCalendar() throws -> EKCalendar {
        if let existing = writableCalendars().first(where: { $0.title == Self.dedicatedCalendarTitle }) {
            return existing
        }
        let sources = eventStore.sources
        guard let source = sources.first(where: { $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud") })
            ?? eventStore.defaultCalendarForNewEvents?.source
            ?? sources.first(where: { $0.sourceType == .local })
        else {
            throw NSError(domain: "DeviceCalendarManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No calendar account can hold a new calendar."
            ])
        }
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = Self.dedicatedCalendarTitle
        calendar.source = source
        calendar.cgColor = UIColor.systemTeal.cgColor
        try eventStore.saveCalendar(calendar, commit: true)
        return calendar
    }

    func resync() {
        queue.async { self.syncAll(force: true) }
    }

    private var hasFullAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Runs on `queue`. `force` also reapplies calendar, title and alert to unchanged events.
    private func syncAll(force: Bool = false) {
        guard isEnabled, hasFullAccess, let calendarIdentifier,
              let calendar = eventStore.calendar(withIdentifier: calendarIdentifier) else { return }
        for kind in DeviceCalendarEvent.allCases {
            guard let date = latestDates[kind] else { continue } // no device, or not read yet: leave the event alone
            sync(kind, to: date, in: calendar, force: force)
        }
    }

    private func sync(_ kind: DeviceCalendarEvent, to date: Date, in calendar: EKCalendar, force: Bool) {
        let key = kind.rawValue
        let dateChanged = syncedDates[key].map { abs($0.timeIntervalSince(date)) > Self.moveThreshold } ?? true
        let existing = eventIDs[key].flatMap { eventStore.event(withIdentifier: $0) }

        // Deleted by hand for the current device: respect that until the next device.
        if existing == nil, !dateChanged { return }
        if existing != nil, !dateChanged, !force { return }

        let event = existing ?? EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = kind.title
        event.notes = kind.notes
        if dateChanged || existing == nil {
            event.startDate = date
            event.endDate = date.addingTimeInterval(15 * 60)
        }
        event.alarms = alertMinutesBefore.map { [EKAlarm(relativeOffset: TimeInterval(-$0 * 60))] }

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            eventIDs[key] = event.eventIdentifier
            syncedDates[key] = date
            debug(.service, "Device calendar: \(key) set to \(date)")
        } catch {
            warning(.service, "Device calendar: could not save \(key)", error: error)
        }
    }
}

// MARK: - Settings

struct DeviceCalendarSettingsView: View {
    let manager: DeviceCalendarManager

    @State private var isEnabled = false
    @State private var calendarIdentifier: String?
    @State private var alertMinutesBefore: Int?
    @State private var calendars: [EKCalendar] = []
    @State private var hasAccess = true
    @State private var errorText: String?

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private static let alertChoices: [(String, Int?)] = [
        ("None", nil), ("At time of event", 0), ("1 hour before", 60), ("2 hours before", 120),
        ("4 hours before", 240), ("1 day before", 24 * 60)
    ]

    var body: some View {
        List {
            Section {
                Toggle(isOn: $isEnabled) { Text(verbatim: "Device Change Events") }
            } footer: {
                Text(verbatim: """
                Adds “Pod expires”, “Pod stops insulin”, “CGM sensor expires” and “CGM sensor stops” \
                events, and moves them each time you start a new pod or sensor.
                """)
            }.listRowBackground(Color.chart)

            if isEnabled, !hasAccess {
                Section {
                    Text(verbatim: "Trio needs Full Access to calendars: Settings › Trio › Calendars.")
                    Button { openSettings() } label: { Text(verbatim: "Open Settings") }
                }.listRowBackground(Color.chart)
            } else if isEnabled {
                Section {
                    Picker(selection: $calendarIdentifier) {
                        Text(verbatim: "Choose…").tag(String?.none)
                        ForEach(calendars, id: \.calendarIdentifier) { calendar in
                            Text(verbatim: "\(calendar.title) (\(calendar.source.title))")
                                .tag(Optional(calendar.calendarIdentifier))
                        }
                    } label: { Text(verbatim: "Calendar") }
                    if !calendars.contains(where: { $0.title == BaseDeviceCalendarManager.dedicatedCalendarTitle }) {
                        Button { createCalendar() } label: {
                            Text(verbatim: "Create “\(BaseDeviceCalendarManager.dedicatedCalendarTitle)” Calendar")
                        }
                    }
                } footer: {
                    Text(verbatim: """
                    A calendar of its own is easiest: it can have its own colour, be hidden or shared with family, \
                    and is never cleared by the glucose events above.
                    """)
                }.listRowBackground(Color.chart)

                Section {
                    Picker(selection: $alertMinutesBefore) {
                        ForEach(Self.alertChoices, id: \.0) { choice in
                            Text(verbatim: choice.0).tag(choice.1)
                        }
                    } label: { Text(verbatim: "Alert") }
                }.listRowBackground(Color.chart)
            }

            if let errorText {
                Text(verbatim: errorText).foregroundStyle(.red).font(.footnote)
            }
        }
        .listSectionSpacing(sectionSpacing)
        .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle(Text(verbatim: "Device Change Events"))
        .onAppear {
            isEnabled = manager.isEnabled
            calendarIdentifier = manager.calendarIdentifier
            alertMinutesBefore = manager.alertMinutesBefore
            if isEnabled { Task { await loadCalendars() } }
        }
        .onChange(of: isEnabled) { _, enabled in
            manager.isEnabled = enabled
            if enabled { Task { await loadCalendars() } }
        }
        .onChange(of: calendarIdentifier) { _, id in manager.calendarIdentifier = id }
        .onChange(of: alertMinutesBefore) { _, minutes in manager.alertMinutesBefore = minutes }
    }

    @MainActor private func loadCalendars() async {
        hasAccess = await manager.requestAccess()
        guard hasAccess else { return }
        calendars = manager.writableCalendars()
        if calendarIdentifier == nil {
            // First time on: default to the dedicated calendar rather than a personal one.
            createCalendar()
        }
    }

    private func createCalendar() {
        do {
            let calendar = try manager.createDedicatedCalendar()
            calendars = manager.writableCalendars()
            calendarIdentifier = calendar.calendarIdentifier
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
