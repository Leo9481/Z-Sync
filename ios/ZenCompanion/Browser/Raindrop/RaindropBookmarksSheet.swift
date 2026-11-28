import SwiftUI

/// Raindrop bookmarks: collections as folders, a tap opens a bookmark as a
/// new tab, a swipe moves it to Raindrop's Trash.
struct RaindropBookmarksSheet: View {
    let onOpen: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @Bindable private var raindrop = RaindropSettings.shared

    var body: some View {
        NavigationStack {
            Group {
                if raindrop.isConnected {
                    RaindropFolderList(parentID: nil, title: "Raindrop", onOpen: open)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "cloud")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(verbatim: "Raindrop isn't connected")
                            .font(.headline)
                        Text(verbatim: "Add your Raindrop test token in Settings → Raindrop.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
        }
        .task { await raindrop.refreshCollections() }
    }

    private func open(_ url: URL) {
        dismiss()
        onOpen(url)
    }
}

/// One level of the tree: the built-in folders at the top, then the
/// collections under `parentID`; inside a collection, its sub-collections
/// and then its bookmarks.
private struct RaindropFolderList: View {
    /// nil for the top level.
    let parentID: Int?
    let title: String
    let onOpen: (URL) -> Void

    @Bindable private var raindrop = RaindropSettings.shared

    var body: some View {
        List {
            Section {
                if parentID == nil {
                    folderLink(id: RaindropCollection.all, title: "All bookmarks", symbol: "tray.full", count: nil)
                    folderLink(id: RaindropCollection.unsorted, title: "Unsorted", symbol: "tray", count: nil)
                }
                ForEach(raindrop.collections.filter { $0.parentID == parentID }) { collection in
                    folderLink(id: collection.id, title: collection.title, symbol: "folder", count: collection.count)
                }
            }
            if let parentID {
                RaindropBookmarkRows(collectionID: parentID, onOpen: onOpen)
            }
        }
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func folderLink(id: Int, title: String, symbol: String, count: Int?) -> some View {
        NavigationLink {
            RaindropFolderList(parentID: id, title: title, onOpen: onOpen)
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if let count {
                    Text(verbatim: "\(count)").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A collection's bookmarks, newest first, 50 at a time.
private struct RaindropBookmarkRows: View {
    let collectionID: Int
    let onOpen: (URL) -> Void

    @State private var items: [Raindrop] = []
    @State private var page = 0
    @State private var finished = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Section {
            ForEach(items) { item in
                Button {
                    onOpen(item.link)
                } label: {
                    HStack(spacing: 12) {
                        Favicon(urlString: item.link.absoluteString, size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.title)
                                .foregroundStyle(Color.primary)
                                .lineLimit(2)
                            Text(verbatim: item.domain)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        Task { await remove(item) }
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                .onAppear {
                    if item.id == items.last?.id { Task { await loadMore() } }
                }
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let error {
                Text(verbatim: error).foregroundStyle(.red)
            } else if finished && items.isEmpty {
                Text(verbatim: "No bookmarks here").foregroundStyle(.secondary)
            }
        }
        .task { if items.isEmpty { await loadMore() } }
    }

    private func loadMore() async {
        guard !loading, !finished else { return }
        loading = true
        error = nil
        do {
            let next = try await RaindropAPI.raindrops(in: collectionID, page: page)
            items += next.filter { new in !items.contains { $0.id == new.id } }
            page += 1
            finished = next.count < 50
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func remove(_ item: Raindrop) async {
        do {
            try await RaindropAPI.remove(item.id)
            items.removeAll { $0.id == item.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
