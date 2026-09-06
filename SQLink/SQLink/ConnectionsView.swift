import SwiftUI

struct ConnectionsView: View {
    @EnvironmentObject var store: ConnectionStore
    @State private var editorTarget: ConnectionProfile?

    var body: some View {
        NavigationView {
            List {
                if store.profiles.isEmpty {
                    Text("还没有连接，点右上角 + 添加一个")
                        .foregroundColor(.secondary)
                }
                ForEach(store.profiles) { p in
                    NavigationLink(destination: DatabaseBrowserView(profile: p)) {
                        ConnectionRow(profile: p, onEdit: { editorTarget = p })
                    }
                    .swipeActions(edge: .trailing) {
                        Button { editorTarget = p } label: { Label("编辑", systemImage: "pencil") }
                            .tint(.accentColor)
                        Button(role: .destructive) { store.remove(p) } label: { Label("删除", systemImage: "trash") }
                    }
                    .swipeActions(edge: .leading) {
                        Button { editorTarget = p } label: { Label("编辑", systemImage: "pencil") }
                            .tint(.accentColor)
                    }
                    .contextMenu {
                        Button { editorTarget = p } label: { Label("编辑", systemImage: "pencil") }
                        Button(role: .destructive) { store.remove(p) } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
            .navigationTitle("SQLink")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { editorTarget = ConnectionProfile() } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editorTarget) { target in
                ConnectionEditorView(target: target)
            }
        }
    }
}
