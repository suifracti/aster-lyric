import Combine
import Foundation
import SwiftUI

public enum SleepTimerOption: Int, CaseIterable, Identifiable {
    case off = 0, fifteen = 15, thirty = 30, sixty = 60, trackEnd = -1
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .off: return "关闭"
        case .trackEnd: return "本曲结束后"
        default: return "\(rawValue) 分钟"
        }
    }
}

@MainActor
public final class SleepTimerController: ObservableObject {
    @Published public private(set) var option: SleepTimerOption = .off
    @Published public private(set) var remainingSeconds = 0
    private var deadline: Date?
    private var trackID: String?
    private var pause: (() -> Void)?
    private var task: Task<Void, Never>?

    public func start(_ option: SleepTimerOption, trackID: String?, pause: @escaping () -> Void) {
        task?.cancel()
        self.option = option
        self.trackID = trackID
        self.pause = option == .off ? nil : pause
        deadline = option.rawValue > 0 ? Date().addingTimeInterval(Double(option.rawValue * 60)) : nil
        remainingSeconds = max(0, option.rawValue * 60)
        guard deadline != nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.updateRemainingTime()
            }
        }
    }

    private func updateRemainingTime() {
        guard let deadline else { return }
        remainingSeconds = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
        if remainingSeconds == 0 { fire() }
    }

    public func updateTrackRemaining(_ seconds: TimeInterval) {
        guard option == .trackEnd else { return }
        let remaining = max(0, Int(ceil(seconds)))
        if remaining != remainingSeconds { remainingSeconds = remaining }
    }

    public func trackChanged(to id: String?) {
        if option == .trackEnd, let trackID, let id, trackID != id { fire() }
    }
    public func trackEnded() { if option == .trackEnd { fire() } }
    private func fire() {
        let action = pause
        task?.cancel()
        task = nil
        deadline = nil
        pause = nil
        option = .off
        remainingSeconds = 0
        action?()
    }
    deinit { task?.cancel() }
}

struct SleepTimerControls: View {
    @ObservedObject var timer: SleepTimerController
    let select: (SleepTimerOption) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("睡眠定时")
                Spacer()
                if timer.option != .off {
                    Text(String(format: "%d:%02d", timer.remainingSeconds / 60, timer.remainingSeconds % 60))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Picker("睡眠定时", selection: Binding(get: { timer.option }, set: select)) {
                ForEach(SleepTimerOption.allCases) { Text($0.title).tag($0) }
            }.labelsHidden()
        }
    }
}
