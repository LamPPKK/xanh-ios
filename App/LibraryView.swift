import SwiftUI

struct LibraryView: View {
    enum Section: String, CaseIterable, Identifiable {
        case bookmarks = "Bookmarks"
        case history = "History"
        case archive = "Archive"
        var id: String { rawValue }
    }

    @Bindable var store: BrowserStore
    @Binding var isPresented: Bool
    @State private var section: Section = .bookmarks

    private var profileBookmarks: [Bookmark] {
        guard let profileID = store.activeProfile?.id else { return [] }
        return store.bookmarks.filter { $0.profileID == profileID }
    }

    private var profileHistory: [HistoryVisit] {
        guard let profileID = store.activeProfile?.id else { return [] }
        return store.history.filter { $0.profileID == profileID }
    }

    private var profileArchivedTabs: [ArchivedTab] {
        guard let profileID = store.activeProfile?.id else { return [] }
        return store.archivedTabs.filter { $0.profileID == profileID }
    }

    var body: some View {
        NavigationStack {
            libraryContent
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { libraryToolbar }
        }
        .preferredColorScheme(.dark)
    }

    private var libraryContent: some View {
        ZStack {
            Color.xanhBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                Picker("Library section", selection: $section) {
                    ForEach(Section.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(16)

                sectionContent
            }
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .bookmarks:
            bookmarksList
        case .history:
            historyList
        case .archive:
            archiveList
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            leadingToolbarButton
        }
        ToolbarItem(placement: .confirmationAction) {
            Button { isPresented = false } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Done")
        }
    }

    private var leadingToolbarButton: AnyView {
        if section == .bookmarks, canToggleActiveBookmark {
            let removing = store.isBookmarked(store.activeTab?.url)
            return AnyView(
                Button {
                    store.toggleBookmarkForActiveTab()
                } label: {
                    Image(systemName: removing ? "bookmark.slash" : "bookmark")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(removing ? "Remove current bookmark" : "Bookmark current page")
                .accessibilityIdentifier("library.bookmark-toggle")
            )
        }
        if section == .history, !profileHistory.isEmpty {
            return AnyView(
                Button("Clear", role: .destructive) {
                    if let profileID = store.activeProfile?.id {
                        store.clearHistory(for: profileID)
                    }
                }
            )
        }
        if section == .archive, !profileArchivedTabs.isEmpty {
            return AnyView(
                Button("Clear", role: .destructive) {
                    if let profileID = store.activeProfile?.id {
                        store.clearArchivedTabs(for: profileID)
                    }
                }
            )
        }
        return AnyView(EmptyView())
    }

    private var canToggleActiveBookmark: Bool {
        store.activeTab?.url != nil && store.activeTab?.isPrivate == false
    }

    private var bookmarksList: some View {
        Group {
            if profileBookmarks.isEmpty {
                emptyState("No bookmarks", icon: "bookmark")
            } else {
                List {
                    ForEach(profileBookmarks) { bookmark in
                        navigationRow(title: bookmark.title, url: bookmark.url, icon: "bookmark.fill")
                            .swipeActions {
                                Button("Delete", role: .destructive) { store.removeBookmark(bookmark.id) }
                            }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var historyList: some View {
        Group {
            if profileHistory.isEmpty {
                emptyState("No regular history", icon: "clock")
            } else {
                List(profileHistory) { visit in
                    navigationRow(title: visit.title, url: visit.url, icon: "clock.arrow.circlepath")
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var archiveList: some View {
        Group {
            if profileArchivedTabs.isEmpty {
                emptyState(
                    "No archived tabs",
                    icon: "archivebox",
                    description: "Closed regular tabs stay here for 30 days. Private tabs are never archived."
                )
            } else {
                List {
                    ForEach(profileArchivedTabs) { archived in
                        Button {
                            if store.restoreArchivedTab(archived.id) != nil {
                                isPresented = false
                            }
                        } label: {
                            libraryRowLabel(
                                title: archived.title,
                                url: archived.url,
                                icon: archived.pinnedAt == nil ? "arrow.uturn.backward.circle.fill" : "pin.fill"
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            archived.pinnedAt == nil
                                ? "Restore \(archived.title)"
                                : "Restore pinned \(archived.title)"
                        )
                        .accessibilityIdentifier("library.archive.restore")
                        .swipeActions {
                            Button("Delete", role: .destructive) { store.removeArchivedTab(archived.id) }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func navigationRow(title: String, url: URL, icon: String) -> some View {
        Button {
            try? store.navigate(url.absoluteString)
            isPresented = false
        } label: {
            libraryRowLabel(title: title, url: url, icon: icon)
        }
        .buttonStyle(.plain)
    }

    private func libraryRowLabel(title: String, url: URL, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.xanhGreen)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).lineLimit(1)
                Text(url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(Color.xanhMuted)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 44)
    }

    private func emptyState(
        _ title: String,
        icon: String,
        description: String = "Private activity never appears here."
    ) -> some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(description))
            .foregroundStyle(Color.xanhMuted)
    }
}
