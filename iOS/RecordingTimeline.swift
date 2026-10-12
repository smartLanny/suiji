import SwiftUI

enum PhoneTimelineEntry: Identifiable {
    case recording(Recording)
    case continuousGroup([Recording])

    var id: String {
        switch self {
        case .recording(let recording): return "recording-\(recording.id.uuidString)"
        case .continuousGroup(let recordings):
            return "continuous-\(recordings.first?.id.uuidString ?? "")"
        }
    }
}

func phoneTimelineEntries(from recordings: [Recording], calendar: Calendar = .current) -> [PhoneTimelineEntry] {
    let sorted = recordings.sorted { $0.recordedAt < $1.recordedAt }
    var entries: [PhoneTimelineEntry] = []
    var index = 0

    while index < sorted.count {
        let first = sorted[index]
        var end = index + 1
        if first.mode == .continuous {
            while end < sorted.count && canJoinContinuousRecordings(sorted[end - 1], sorted[end], calendar: calendar) {
                end += 1
            }
        }
        let run = Array(sorted[index..<end])
        entries.append(run.count > 1 ? .continuousGroup(run) : .recording(first))
        index = end
    }
    return entries
}

private func canJoinContinuousRecordings(_ first: Recording, _ next: Recording, calendar: Calendar) -> Bool {
    guard first.mode == .continuous, next.mode == .continuous,
          first.source == next.source,
          calendar.isDate(first.recordedAt, inSameDayAs: next.recordedAt),
          first.duration.isFinite, first.duration >= 0,
          next.duration.isFinite, next.duration >= 0 else { return false }
    let gap = next.recordedAt.timeIntervalSince(first.recordedAt.addingTimeInterval(first.duration))
    return (-0.5...5).contains(gap)
}

struct ContinuousRecordingGroupRow: View {
    let recordings: [Recording]
    let theme: CompanionTheme
    @State private var expanded = false

    private var first: Recording { recordings[0] }
    private var last: Recording { recordings[recordings.count - 1] }
    private var totalDuration: Double { recordings.reduce(0) { $0 + max(0, $1.duration) } }
    private var totalGap: Double {
        zip(recordings, recordings.dropFirst()).reduce(0) { total, pair in
            total + max(0, pair.1.recordedAt.timeIntervalSince(pair.0.recordedAt.addingTimeInterval(pair.0.duration)))
        }
    }
    private var rangeText: String {
        "\(clockText(first.recordedAt))–\(clockText(last.recordedAt.addingTimeInterval(max(0, last.duration))))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Text(clockText(first.recordedAt))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.muted)
                .frame(width: 43, alignment: .leading).padding(.top, 2)
            VStack(spacing: 8) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 11)).foregroundStyle(theme.color).frame(width: 14, height: 18)
                Rectangle().fill(Palette.line).frame(width: 0.6)
            }.frame(width: 14)
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("连续录音")
                                .font(.caption.weight(.medium)).foregroundStyle(theme.color)
                            Text(rangeText)
                                .font(.custom("NotoSerifSC-Regular", size: 18)).foregroundStyle(Palette.ink)
                            HStack(spacing: 5) {
                                Text("\(recordings.count) 段 · 实录 \(durationText(totalDuration))")
                                if totalGap > 1 { Text("· 间隔 \(durationText(totalGap))") }
                            }.font(.caption).foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("连续录音，\(rangeText)，\(recordings.count) 段，实际录音\(durationText(totalDuration))\(totalGap > 1 ? "，间隔\(durationText(totalGap))" : "")")
                .accessibilityHint(expanded ? "收起片段" : "展开并打开单条录音")

                if expanded {
                    VStack(spacing: 0) {
                        ForEach(recordings) { recording in
                            NavigationLink(value: recording.id) {
                                HStack(alignment: .top, spacing: 9) {
                                    Text(clockText(recording.recordedAt))
                                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.muted)
                                        .frame(width: 40, alignment: .leading).padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(recording.transcript ?? recording.title)
                                            .font(.system(size: 14)).lineLimit(2).foregroundStyle(Palette.ink)
                                        Text("\(durationText(recording.duration)) · \(transcriptionLabel(recording))")
                                            .font(.caption).foregroundStyle(Palette.muted)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Palette.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if recording.id != last.id {
                                Rectangle().fill(Palette.line).frame(height: 0.5).padding(.leading, 49)
                            }
                        }
                    }
                    .padding(.top, 10)
                }

                Rectangle().fill(Palette.line).frame(height: 0.5).padding(.top, 15)
            }
            .padding(.bottom, 20)
        }
    }
}

private func clockText(_ date: Date) -> String {
    date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
}
