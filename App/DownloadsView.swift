import SwiftUI

struct DownloadsView: View {
    @Bindable var store: BrowserStore
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color.xanhBackground.ignoresSafeArea()
                if store.downloadCenter.items.isEmpty {
                    ScrollView {
                        VStack(spacing: 14) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 52, weight: .regular))
                                .foregroundStyle(Color.xanhMuted)
                                .accessibilityHidden(true)
                            Text("No downloads")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Color.xanhCream)
                            Text("Files you download from regular tabs appear here. Private downloads are removed with their private space.")
                                .font(.body)
                                .foregroundStyle(Color.xanhMuted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: 520)
                        .padding(32)
                    }
                } else {
                    List {
                        downloadSummary
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        ForEach(store.downloadCenter.items) { item in
                            DownloadRow(
                                item: item,
                                pause: { store.pauseDownload(item.id) },
                                resume: { store.resumeDownload(item.id) },
                                remove: { store.removeDownload(item.id) }
                            )
                            .listRowBackground(Color.xanhPanel)
                            .accessibilityIdentifier("download.row")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .accessibilityIdentifier("downloads.list")
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var downloadSummary: some View {
        HStack(spacing: 12) {
            XanhBrandMark(size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("TRANSFER DECK")
                    .font(.caption.monospaced().weight(.black))
                    .tracking(1.1)
                    .foregroundStyle(Color.xanhGreen)
                Text(summaryText)
                    .font(.subheadline)
                    .foregroundStyle(Color.xanhMuted)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var summaryText: String {
        let active = store.downloadCenter.activeCount
        let total = store.downloadCenter.items.count
        return "\(active) active · \(total) total"
    }
}

private struct DownloadRow: View {
    @Bindable var item: BrowserDownloadItem
    let pause: () -> Void
    let resume: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.xanhRaised)
                    Image(systemName: fileSymbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(item.isPrivate ? Color.xanhLeaf : Color.xanhGreen)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.filename)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Text(item.state.label)
                        .font(.caption)
                        .foregroundStyle(stateColor)
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                actionControl
            }

            if item.state == .downloading, let progress = item.progress {
                ProgressView(progress)
                    .tint(Color.xanhGreen)
                    .accessibilityLabel("Download progress")
            }
        }
        .padding(.vertical, 6)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", role: .destructive, action: remove)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actionControl: some View {
        if item.canPause {
            Button(action: pause) {
                Image(systemName: "pause.fill")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .tint(Color.xanhMuted)
            .accessibilityLabel("Pause \(item.filename)")
        } else if item.canResume {
            Button(action: resume) {
                Image(systemName: "play.fill")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.xanhGreen)
            .foregroundStyle(Color.xanhBackground)
            .accessibilityLabel("Resume \(item.filename)")
        } else if item.canShare {
            ShareLink(item: item.destinationURL) {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .tint(Color.xanhGreen)
            .accessibilityLabel("Share \(item.filename)")
        } else {
            Button(action: remove) {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .tint(Color.xanhLeaf)
            .accessibilityLabel("Remove \(item.filename)")
        }
    }

    private var fileSymbol: String {
        if item.isPrivate { return "eye.slash" }
        switch item.destinationURL.pathExtension.lowercased() {
        case "mp4", "mov", "m4v": return "film"
        case "mp3", "m4a", "wav", "flac": return "waveform"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "7z", "rar": return "archivebox"
        default: return "doc"
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .completed: Color.xanhGreen
        case .failed, .cancelled: Color.xanhLeaf
        case .downloading, .paused: Color.xanhMuted
        }
    }
}
