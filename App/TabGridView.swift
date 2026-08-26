import SwiftUI

struct TabGridView: View {
    @Bindable var store: BrowserStore
    @Binding var isPresented: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var newProfileName = ""
    @State private var showNewProfile = false

    private let columns = [GridItem(.adaptive(minimum: 168), spacing: 14)]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.xanhBackground.ignoresSafeArea()
                if horizontalSizeClass == .regular {
                    HStack(spacing: 0) {
                        spaceSidebar
                            .frame(width: 230)
                        Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1)
                        tabGrid
                    }
                } else {
                    VStack(spacing: 0) {
                        spaceRail
                        tabGrid
                    }
                }
            }
            .navigationTitle("Open orbits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("New private space", systemImage: "eye.slash") {
                            store.createPrivateSpace()
                        }
                        Button("New profile", systemImage: "person.crop.circle.badge.plus") {
                            showNewProfile = true
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Create space or profile")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Done")
                }
            }
            .alert("New profile", isPresented: $showNewProfile) {
                TextField("Profile name", text: $newProfileName)
                Button("Create") {
                    store.createProfile(name: newProfileName)
                    newProfileName = ""
                }
                Button("Cancel", role: .cancel) { newProfileName = "" }
            } message: {
                Text("Profiles use separate persistent WebKit data stores.")
            }
        }
        .preferredColorScheme(.dark)
    }

    private var spaceRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.spaces) { space in
                    spaceButton(space, compact: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.xanhPanel.opacity(0.98))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.xanhBorder).frame(height: 1) }
    }

    private var spaceSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            XanhSectionLabel(title: "Spaces", index: "01")
                .padding(.horizontal, 16)
                .padding(.top, 18)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.spaces) { space in
                        spaceButton(space, compact: false)
                    }
                }
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
        }
        .background(Color.xanhPanel)
    }

    private var tabGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    XanhSectionLabel(title: "Tabs in this space", index: "02")
                    Text("\(store.tabsInSelectedSpace.count)")
                        .font(.caption.monospaced().weight(.black))
                        .foregroundStyle(Color.xanhGreen)
                }
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(store.tabsInSelectedSpace) { tab in
                        tabCard(tab)
                    }
                    newTabCard
                }
            }
            .padding(16)
        }
    }

    private func spaceButton(_ space: BrowserSpace, compact: Bool) -> some View {
        Button {
            Task { await store.selectSpace(space.id) }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(space.storageMode == .ephemeral ? Color.xanhLeaf : Color.xanhGreen)
                    .frame(width: 7, height: 7)
                Text(space.name.uppercased())
                Spacer(minLength: compact ? 0 : 8)
                Text("\(store.tabs.filter { $0.spaceID == space.id }.count)")
                    .foregroundStyle(Color.xanhMuted)
            }
            .font(.caption.monospaced().weight(.bold))
            .padding(.horizontal, 13)
            .frame(maxWidth: compact ? nil : .infinity, minHeight: 44, alignment: .leading)
            .background(
                store.selectedSpaceID == space.id ? Color.xanhRaised : Color.clear,
                in: RoundedRectangle(cornerRadius: compact ? 22 : 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 22 : 12, style: .continuous)
                    .stroke(store.selectedSpaceID == space.id ? Color.xanhGreen.opacity(0.55) : Color.xanhBorder)
            }
        }
        .buttonStyle(.plain)
    }

    private func tabCard(_ tab: BrowserTab) -> some View {
        SwipeClosableTabCard(
            tab: tab,
            thumbnail: store.thumbnail(for: tab.id),
            isSelected: store.selectedTabID == tab.id,
            onOpen: {
                store.activateTab(tab.id)
                isPresented = false
            },
            onTogglePin: {
                store.togglePinned(tab.id)
            },
            onClose: {
                store.closeTab(tab.id)
            }
        )
    }

    private var newTabCard: some View {
        Button {
            _ = store.createTab()
            isPresented = false
        } label: {
            VStack(spacing: 11) {
                Image(systemName: "plus")
                    .font(.title2.weight(.medium))
                    .frame(width: 48, height: 48)
                    .background(Color.xanhRaised, in: Circle())
                Text("NEW ORBIT")
                    .font(.headline.weight(.black))
                Text("Open a clean tab in this space")
                    .font(.caption)
                    .foregroundStyle(Color.xanhMuted)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Color.xanhGreen)
            .frame(maxWidth: .infinity, minHeight: 224)
            .padding(16)
            .background(Color.xanhPanel)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.xanhGreen.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New tab")
        .accessibilityIdentifier("tabs.new")
    }
}

private struct SwipeClosableTabCard: View {
    let tab: BrowserTab
    let thumbnail: UIImage?
    let isSelected: Bool
    let onOpen: () -> Void
    let onTogglePin: () -> Void
    let onClose: () -> Void

    @State private var dragOffset = 0.0

    var body: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.xanhLeaf.opacity(0.9))
                .overlay(alignment: .trailing) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.xanhBackground)
                        .padding(.trailing, 24)
                }

            ZStack(alignment: .topTrailing) {
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 0) {
                        ZStack(alignment: .bottomLeading) {
                            LinearGradient(
                                colors: [Color.xanhRaised, Color.xanhPanel],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            if let thumbnail {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .clipped()
                            } else {
                                ZStack {
                                    XanhSignalField()
                                    if tab.url == nil {
                                        XanhBrandMark(size: 72)
                                    } else {
                                        Image(systemName: tab.isPrivate ? "eye.slash" : "globe.americas.fill")
                                            .font(.system(size: 32, weight: .light))
                                            .foregroundStyle(tab.isPrivate ? Color.xanhLeaf : Color.xanhGreen)
                                    }
                                }
                            }
                        }
                        .frame(height: 144)

                        VStack(alignment: .leading, spacing: 7) {
                            Text(isSelected ? "ACTIVE" : tab.isPinned ? "PINNED" : tab.isPrivate ? "PRIVATE" : "BACKGROUND")
                                .font(.caption.monospaced().weight(.black))
                                .foregroundStyle(isSelected ? Color.xanhBackground : Color.xanhCream)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(
                                    isSelected ? Color.xanhGreen : Color.black.opacity(0.58),
                                    in: Capsule()
                                )
                                .fixedSize(horizontal: false, vertical: true)
                            Text(tab.title)
                                .font(.headline.weight(.bold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(tab.url?.absoluteString ?? "Xanh home")
                                .font(.caption)
                                .foregroundStyle(Color.xanhMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                    }
                    .background(Color.xanhPanel)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(isSelected ? Color.xanhGreen : Color.white.opacity(0.1), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tab.title), \(tab.url?.host() ?? "Xanh home")")
                .accessibilityValue(accessibilityState)
                .accessibilityHint("Double-tap to open. Swipe left to close. Pinned tabs are protected from automatic Archive.")
                .accessibilityIdentifier("tab.card")
                .accessibilityActions {
                    if tab.url != nil {
                        Button(tab.isPinned ? "Unpin tab" : "Pin tab", action: onTogglePin)
                    }
                    Button("Close tab", action: onClose)
                }

                HStack(spacing: 2) {
                    if tab.url != nil {
                        Button(action: onTogglePin) {
                            Image(systemName: tab.isPinned ? "pin.fill" : "pin")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.58), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(tab.isPinned ? Color.xanhGreen : Color.xanhCream)
                        .accessibilityLabel(tab.isPinned ? "Unpin \(tab.title)" : "Pin \(tab.title)")
                        .accessibilityIdentifier("tab.pin")
                    }

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.58), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close \(tab.title)")
                    .accessibilityIdentifier("tab.close")
                }
                .padding(4)
            }
            .offset(x: dragOffset)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 16)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragOffset = min(0, max(-120, value.translation.width))
                }
                .onEnded { value in
                    let shouldClose = value.translation.width < -72 || value.predictedEndTranslation.width < -120
                    if shouldClose {
                        withAnimation(.easeIn(duration: 0.16)) { dragOffset = -320 }
                        onClose()
                    } else {
                        withAnimation(.snappy(duration: 0.22)) { dragOffset = 0 }
                    }
                }
        )
    }

    private var accessibilityState: String {
        var states: [String] = []
        if isSelected { states.append("Active") }
        if tab.isPrivate { states.append("Private") }
        if tab.isPinned { states.append("Pinned") }
        if states.isEmpty { states.append("Background") }
        return states.map { "\($0) tab" }.joined(separator: ", ")
    }
}
