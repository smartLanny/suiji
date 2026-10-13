struct RecordingProgressMonitor {
    private let stallInterval = 10.0
    private var lastAudioTime = 0.0
    private var lastProgressUptime: Double?

    mutating func reset(at uptime: Double) {
        lastAudioTime = 0
        lastProgressUptime = uptime
    }

    mutating func observe(audioTime: Double, at uptime: Double) -> Bool {
        if audioTime.isFinite, audioTime > lastAudioTime {
            lastAudioTime = audioTime
            lastProgressUptime = uptime
        }
        guard let lastProgressUptime else { return false }
        return uptime - lastProgressUptime > stallInterval
    }
}
