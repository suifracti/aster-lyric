import SwiftUI

struct LyricRecallView: View {
    let page: LibraryPassagePage
    @State var session: LyricRecallSession
    let showsTranslation: Bool
    let showsReading: Bool
    let returnToLine: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { returnToLine(session.cue.id) } label: { Label("返回原词", systemImage: "chevron.left") }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                Spacer()
                Text("接下一句").font(.callout.weight(.medium))
                Text("\(session.lineNumber) / \(session.lineCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 19).padding(.vertical, 12)
            Divider()
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 11) {
                            ListeningArtwork(url: page.entry.artworkURL)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(page.entry.title).font(.headline)
                                Text(page.entry.artist).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        block(session.cue, isAnswer: false)
                        Spacer(minLength: 0)
                        if let answer = session.revealedAnswer {
                            Divider()
                            block(answer, isAnswer: true)
                            HStack {
                                KeepLyricButton(text: answer.original, translation: answer.translation, trackKey: page.entry.trackStableKey,
                                                title: page.entry.title, artist: page.entry.artist, artworkURL: page.entry.artworkURL,
                                                lyricsVersionID: page.originalVersionID, lineIndex: answer.id)
                                Spacer()
                                Button {
                                    if session.canAdvance { session.advance() } else { returnToLine(answer.id) }
                                } label: {
                                    Label(session.canAdvance ? "再接一句" : "读完整词", systemImage: "arrow.right")
                                }
                                .buttonStyle(.borderedProminent).tint(WorkspacePalette.sleeve).keyboardShortcut(.defaultAction)
                            }
                        } else {
                            Button { session.reveal() } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "eye")
                                    Text("揭晓下一句").font(.headline)
                                    Spacer()
                                    Image(systemName: "return").font(.caption)
                                }
                                .foregroundStyle(WorkspacePalette.ink)
                                .padding(17).frame(maxWidth: .infinity, minHeight: 66)
                                .background(WorkspacePalette.selection, in: RoundedRectangle(cornerRadius: 9))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 580, minHeight: max(210, geometry.size.height - 40), alignment: .topLeading)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    .padding(20).frame(maxWidth: .infinity)
                }
            }
        }
        .background(WorkspacePalette.paper)
    }

    private func block(_ line: LibraryPassagePage.Line, isAnswer: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(line.original)
                .font(.system(size: isAnswer ? 26 : 23, weight: .medium, design: .serif))
                .foregroundStyle(isAnswer ? WorkspacePalette.ink : .primary)
            if let reading = line.reading, showsReading && !reading.isEmpty {
                Text(reading).font(.caption).foregroundStyle(WorkspacePalette.ink)
            }
            if let translation = line.translation, showsTranslation && !translation.isEmpty {
                Text(translation).font(.callout).foregroundStyle(.secondary)
            }
            if let backing = line.background, !backing.isEmpty {
                Label(backing, systemImage: "person.2").font(.caption.italic()).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
}
