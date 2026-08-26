import SwiftUI

struct XanhHomeView: View {
    @Bindable var store: BrowserStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var profileBookmarks: [Bookmark] {
        guard let profileID = store.activeProfile?.id else { return [] }
        return Array(store.bookmarks.filter { $0.profileID == profileID }.prefix(6))
    }

    private var profileHistory: [HistoryVisit] {
        guard let profileID = store.activeProfile?.id else { return [] }
        return Array(store.history.filter { $0.profileID == profileID }.prefix(6))
    }

    private var flightPlanColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [GridItem(.adaptive(minimum: 150), spacing: 12)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                flightPlan

                if !profileBookmarks.isEmpty {
                    XanhSectionLabel(title: "Saved coordinates", index: "02")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 154), spacing: 12)], spacing: 12) {
                        ForEach(profileBookmarks) { bookmark in
                            homeLink(title: bookmark.title, url: bookmark.url, icon: "bookmark.fill")
                        }
                    }
                }

                if !profileHistory.isEmpty {
                    XanhSectionLabel(title: "Recent paths", index: "03")
                    VStack(spacing: 1) {
                        ForEach(profileHistory) { visit in
                            Button {
                                try? store.navigate(visit.url.absoluteString)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(Color.xanhLeaf)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(visit.title).lineLimit(1)
                                        Text(visit.url.host() ?? visit.url.absoluteString)
                                            .font(.caption)
                                            .foregroundStyle(Color.xanhMuted)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 12)
                                    Image(systemName: "arrow.up.right")
                                        .foregroundStyle(Color.xanhGreen)
                                }
                                .padding(14)
                                .frame(minHeight: 52)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Open in the current tab")
                        }
                    }
                    .xanhPanel()
                }
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
        }
        .background {
            ZStack {
                LinearGradient(
                    colors: [Color.xanhBackground, Color(red: 0.045, green: 0.060, blue: 0.043)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                XanhSignalField()
            }
        }
        .accessibilityIdentifier("browser.home")
    }

    private var hero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 28) {
                heroCopy
                Spacer(minLength: 8)
                markVisual.frame(width: 220, height: 210)
            }
            VStack(alignment: .leading, spacing: 22) {
                markVisual.frame(maxWidth: .infinity).frame(height: 150)
                heroCopy
            }
        }
        .padding(dynamicTypeSize.isAccessibilitySize ? 20 : 26)
        .background {
            LinearGradient(
                colors: [Color.xanhPanel, Color.xanhRaised.opacity(0.74)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.xanhBorder, lineWidth: 1)
        }
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 9) {
                Circle().fill(Color.xanhGreen).frame(width: 7, height: 7)
                Text("XANH / WEBKIT 0.1")
                Text("·")
                Text(store.activeProfile?.searchProvider.displayName.uppercased() ?? "BRAVE SEARCH")
                    .foregroundStyle(Color.xanhMuted)
            }
            .font(.caption.monospaced().weight(.bold))
            .foregroundStyle(Color.xanhGreen)
            .fixedSize(horizontal: false, vertical: true)

            Text("MOVE FAST.\nLEAVE LESS.")
                .font(.system(.largeTitle, design: .rounded, weight: .black))
                .tracking(-1.1)
                .foregroundStyle(Color.xanhCream)
                .fixedSize(horizontal: false, vertical: true)

            Text("Profiles separate website data. Spaces keep tabs organized. Private sessions leave no restorable tabs or snapshots.")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.xanhMuted)
                .frame(maxWidth: 580, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var markVisual: some View {
        ZStack {
            Circle()
                .stroke(Color.xanhLeaf.opacity(0.30), lineWidth: 1)
                .padding(18)
            Circle()
                .stroke(Color.xanhGreen.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 8]))
                .padding(42)
            XanhBrandMark(size: dynamicTypeSize.isAccessibilitySize ? 112 : 156)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Xanh Browser arrow mark")
    }

    private var flightPlan: some View {
        VStack(alignment: .leading, spacing: 12) {
            XanhSectionLabel(title: "Privacy status", index: "01")
            LazyVGrid(columns: flightPlanColumns, spacing: 12) {
                statusCard(
                    icon: "person.crop.circle",
                    title: store.activeProfile?.name ?? "No profile",
                    detail: "ISOLATED DATA STORE",
                    accent: .xanhGreen
                )
                statusCard(
                    icon: store.selectedSpace?.storageMode == .ephemeral ? "eye.slash" : "square.stack.3d.up",
                    title: store.selectedSpace?.name ?? "No space",
                    detail: store.selectedSpace?.storageMode == .ephemeral ? "PRIVATE · NOT RESTORED" : "REGULAR SPACE",
                    accent: store.selectedSpace?.storageMode == .ephemeral ? .xanhLeaf : .xanhGreen
                )
                statusCard(
                    icon: "shield.lefthalf.filled",
                    title: store.activeProfile?.blockerEnabled == true ? "Shields active" : "Shields paused",
                    detail: store.activeProfile?.blockerEnabled == true ? "CONTENT RULES ON" : "PROFILE SETTING",
                    accent: store.activeProfile?.blockerEnabled == true ? .xanhGreen : .xanhMuted
                )
            }
        }
    }

    private func statusCard(icon: String, title: String, detail: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Spacer()
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
                .fontWeight(.bold)
                .lineLimit(nil)
            Text(detail)
                .font(.caption2)
                .fontWeight(.bold)
                .monospaced()
                .foregroundStyle(Color.xanhMuted)
                .lineLimit(nil)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .padding(16)
        .xanhPanel()
    }

    private func homeLink(title: String, url: URL, icon: String) -> some View {
        Button {
            try? store.navigate(url.absoluteString)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: icon)
                    .foregroundStyle(Color.xanhLeaf)
                Text(title)
                    .font(.headline.weight(.bold))
                    .lineLimit(2)
                Text(url.host() ?? url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(Color.xanhMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .xanhPanel()
    }
}
