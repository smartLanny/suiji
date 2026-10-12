import Foundation
import AVFAudio
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
import WatchConnectivity
#endif

struct CaptureDiagnosticSnapshot: Sendable {
    let recorderCurrentTime: TimeInterval?
    let recorderIsRecording: Bool?
    let meterLevel: Float
    let logicalIsRecording: Bool
    let elapsedEstimate: TimeInterval
    let currentSegmentUUID: String?
    let accumulatedDuration: TimeInterval
}

private struct CaptureDiagnosticTest: Codable, Sendable {
    let startedAt: String
    let deadline: String
    let durationMinutes: Int
    var completedAt: String?
    var completionReason: String?
}

private struct CaptureDiagnosticEvent: Codable, Sendable {
    let timestamp: String
    let event: String
    let details: [String: String]?
}

private struct CaptureDiagnosticSample: Codable, Sendable {
    let timestamp: String
    let recorderCurrentTime: TimeInterval?
    let recorderIsRecording: Bool?
    let meterLevel: Float
    let logicalIsRecording: Bool
    let elapsedEstimate: TimeInterval
    let currentSegmentUUID: String?
    let accumulatedDuration: TimeInterval
    let batteryLevel: Double?
    let batteryState: String?
    let lowPowerMode: Bool?
    let thermalState: String?
    let scenePhase: String?
    let isLuminanceReduced: Bool?
    let watchConnectivityReachable: Bool?
    let watchConnectivityActivationState: String?
    let watchOutstandingFileTransfers: Int?

    enum CodingKeys: String, CodingKey {
        case timestamp, recorderCurrentTime, recorderIsRecording, meterLevel, logicalIsRecording
        case elapsedEstimate, currentSegmentUUID, accumulatedDuration, batteryLevel
        case batteryState, lowPowerMode, thermalState, scenePhase, isLuminanceReduced
        case watchConnectivityReachable, watchConnectivityActivationState, watchOutstandingFileTransfers
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(timestamp, forKey: .timestamp)
        try values.encode(recorderCurrentTime, forKey: .recorderCurrentTime)
        try values.encode(recorderIsRecording, forKey: .recorderIsRecording)
        try values.encode(meterLevel, forKey: .meterLevel)
        try values.encode(logicalIsRecording, forKey: .logicalIsRecording)
        try values.encode(elapsedEstimate, forKey: .elapsedEstimate)
        try values.encode(currentSegmentUUID, forKey: .currentSegmentUUID)
        try values.encode(accumulatedDuration, forKey: .accumulatedDuration)
        try values.encode(batteryLevel, forKey: .batteryLevel)
        try values.encode(batteryState, forKey: .batteryState)
        try values.encode(lowPowerMode, forKey: .lowPowerMode)
        try values.encode(thermalState, forKey: .thermalState)
        try values.encode(scenePhase, forKey: .scenePhase)
        try values.encode(isLuminanceReduced, forKey: .isLuminanceReduced)
        try values.encode(watchConnectivityReachable, forKey: .watchConnectivityReachable)
        try values.encode(watchConnectivityActivationState, forKey: .watchConnectivityActivationState)
        try values.encode(watchOutstandingFileTransfers, forKey: .watchOutstandingFileTransfers)
    }
}

private struct CaptureDiagnosticDocument: Codable, Sendable {
    let version: Int
    var test: CaptureDiagnosticTest
    var events: [CaptureDiagnosticEvent] = []
    var samples: [CaptureDiagnosticSample] = []
}

private final class CaptureDiagnosticsFileWriter: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.lann.suiji.capture-diagnostics-writer", qos: .utility)
    private let lock = NSLock()
    private var pendingDocument: CaptureDiagnosticDocument?
    private var isDraining = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func submit(_ document: CaptureDiagnosticDocument) {
        lock.lock()
        pendingDocument = document
        let shouldStartDrain = !isDraining
        isDraining = true
        lock.unlock()
        if shouldStartDrain { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            let document = pendingDocument
            pendingDocument = nil
            if document == nil { isDraining = false }
            lock.unlock()
            guard let document else { return }
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(document).write(to: fileURL, options: .atomic)
            } catch {
                // Diagnostics must never interfere with capture.
            }
        }
    }
}

@MainActor
final class CaptureDiagnostics {
    private let writer: CaptureDiagnosticsFileWriter
    private let maximumEntries = 1_600
    private var document: CaptureDiagnosticDocument?
    private var deadline: Date?
    private var timer: Timer?
    private var isActive = false
    private var previousScenePhase: String?
    private var previousLuminanceReduced: Bool?
    #if os(iOS)
    private var enabledBatteryMonitoring = false
    #elseif os(watchOS)
    private var enabledWatchBatteryMonitoring = false
    #endif

    init(root: URL) {
        let fileURL = root.appendingPathComponent("capture-diagnostics.json")
        writer = CaptureDiagnosticsFileWriter(fileURL: fileURL)
    }

    deinit {
        timer?.invalidate()
    }

    func startIfRequested(sample: @escaping () -> CaptureDiagnosticSnapshot?) {
        guard document == nil, let minutes = requestedMinutes(), (1...1_440).contains(minutes) else { return }
        let started = Date()
        let expires = started.addingTimeInterval(TimeInterval(minutes) * 60)
        deadline = expires
        document = CaptureDiagnosticDocument(version: 1, test: CaptureDiagnosticTest(startedAt: Self.timestamp(started),
                                                                                     deadline: Self.timestamp(expires),
                                                                                     durationMinutes: minutes))
        isActive = true
        prepareBatteryMonitoring()
        persist()

        let timer = Timer(fire: Date().addingTimeInterval(1), interval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appendSample(sample())
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func record(_ event: String, details: [String: String] = [:]) {
        guard isActive, var document else { return }
        guard !isExpired(at: Date(), document: &document) else { return }
        guard document.events.count + document.samples.count < maximumEntries else {
            self.document = document
            finish(reason: "entry_limit")
            return
        }
        document.events.append(CaptureDiagnosticEvent(timestamp: Self.timestamp(Date()), event: event,
                                                      details: details.isEmpty ? nil : details))
        self.document = document
        persist()
    }

    func noteLifecycle(scenePhase: String, isLuminanceReduced: Bool) {
        guard isActive else { return }
        guard previousScenePhase != scenePhase || previousLuminanceReduced != isLuminanceReduced else { return }
        previousScenePhase = scenePhase
        previousLuminanceReduced = isLuminanceReduced
        record("lifecycle", details: ["scenePhase": scenePhase,
                                       "isLuminanceReduced": String(isLuminanceReduced)])
    }

    private func appendSample(_ snapshot: CaptureDiagnosticSnapshot?) {
        guard isActive, var document else { return }
        let now = Date()
        guard !isExpired(at: now, document: &document) else { return }
        guard document.events.count + document.samples.count < maximumEntries else {
            self.document = document
            finish(reason: "entry_limit")
            return
        }
        guard let snapshot else { return }
        let environment = deviceEnvironment()
        document.samples.append(CaptureDiagnosticSample(timestamp: Self.timestamp(now),
                                        recorderCurrentTime: snapshot.recorderCurrentTime,
                                        recorderIsRecording: snapshot.recorderIsRecording,
                                        meterLevel: snapshot.meterLevel,
                                        logicalIsRecording: snapshot.logicalIsRecording,
                                        elapsedEstimate: snapshot.elapsedEstimate,
                                        currentSegmentUUID: snapshot.currentSegmentUUID,
                                        accumulatedDuration: snapshot.accumulatedDuration,
                                        batteryLevel: environment.batteryLevel,
                                        batteryState: environment.batteryState,
                                        lowPowerMode: environment.lowPowerMode,
                                        thermalState: environment.thermalState,
                                        scenePhase: previousScenePhase,
                                        isLuminanceReduced: previousLuminanceReduced,
                                        watchConnectivityReachable: environment.watchConnectivityReachable,
                                        watchConnectivityActivationState: environment.watchConnectivityActivationState,
                                        watchOutstandingFileTransfers: environment.watchOutstandingFileTransfers))
        self.document = document
        persist()
    }

    private func isExpired(at now: Date, document: inout CaptureDiagnosticDocument) -> Bool {
        guard let deadline, now >= deadline else { return false }
        self.document = document
        finish(reason: "deadline")
        return true
    }

    private func finish(reason: String) {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        guard var document else { return }
        document.test.completedAt = Self.timestamp(Date())
        document.test.completionReason = reason
        self.document = document
        persist()
        #if os(iOS)
        if enabledBatteryMonitoring {
            UIDevice.current.isBatteryMonitoringEnabled = false
            enabledBatteryMonitoring = false
        }
        #elseif os(watchOS)
        if enabledWatchBatteryMonitoring {
            WKInterfaceDevice.current().isBatteryMonitoringEnabled = false
            enabledWatchBatteryMonitoring = false
        }
        #endif
    }

    private func requestedMinutes() -> Int? {
        let key = "SUIJI_DIAGNOSTICS_MINUTES"
        if let value = ProcessInfo.processInfo.environment[key], let minutes = Int(value) { return minutes }
        let arguments = ProcessInfo.processInfo.arguments
        for (index, argument) in arguments.enumerated() {
            if argument.trimmingCharacters(in: CharacterSet(charactersIn: "-")) == key,
               arguments.indices.contains(index + 1), let minutes = Int(arguments[index + 1]) {
                return minutes
            }
            if let separator = argument.firstIndex(of: "="), argument[argument.index(after: separator)...].isEmpty == false,
               argument[..<separator].trimmingCharacters(in: CharacterSet(charactersIn: "-")) == key,
               let minutes = Int(argument[argument.index(after: separator)...]) {
                return minutes
            }
        }
        return nil
    }

    private func persist() {
        guard let document else { return }
        writer.submit(document)
    }

    private func prepareBatteryMonitoring() {
        #if os(iOS)
        if !UIDevice.current.isBatteryMonitoringEnabled {
            UIDevice.current.isBatteryMonitoringEnabled = true
            enabledBatteryMonitoring = true
        }
        #elseif os(watchOS)
        let device = WKInterfaceDevice.current()
        if !device.isBatteryMonitoringEnabled {
            device.isBatteryMonitoringEnabled = true
            enabledWatchBatteryMonitoring = true
        }
        #endif
    }

    private func deviceEnvironment() -> (batteryLevel: Double?, batteryState: String?, lowPowerMode: Bool?, thermalState: String?, watchConnectivityReachable: Bool?, watchConnectivityActivationState: String?, watchOutstandingFileTransfers: Int?) {
        #if os(iOS)
        let device = UIDevice.current
        let level = Double(device.batteryLevel)
        return ((0...1).contains(level) ? level : nil,
                batteryState(),
                ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState(),
                nil, nil, nil)
        #elseif os(watchOS)
        let device = WKInterfaceDevice.current()
        let level = Double(device.batteryLevel)
        let session = WCSession.default
        let activationState: String?
        switch session.activationState {
        case .notActivated: activationState = "notActivated"
        case .inactive: activationState = "inactive"
        case .activated: activationState = "activated"
        @unknown default: activationState = nil
        }
        return ((0...1).contains(level) ? level : nil,
                batteryState(),
                nil,
                thermalState(),
                WCSession.isSupported() ? session.isReachable : nil,
                WCSession.isSupported() ? activationState : nil,
                WCSession.isSupported() ? session.outstandingFileTransfers.count : nil)
        #else
        return (nil, nil, nil, nil, nil, nil, nil)
        #endif
    }

    private func batteryState() -> String? {
        #if os(iOS)
        switch UIDevice.current.batteryState {
        case .unknown: return nil
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        @unknown default: return nil
        }
        #elseif os(watchOS)
        switch WKInterfaceDevice.current().batteryState {
        case .unknown: return nil
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        @unknown default: return nil
        }
        #else
        return nil
        #endif
    }

    private func thermalState() -> String? {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return nil
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
