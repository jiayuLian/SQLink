import SwiftUI

struct ConnectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: ConnectionStore
    let target: ConnectionProfile

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var user: String
    @State private var password: String
    @State private var database: String
    @State private var useTLS: Bool
    @State private var trustSelfSigned: Bool
    @State private var testMessage: String?
    @State private var testing = false

    private var isNew: Bool {
        !store.profiles.contains(where: { $0.id == target.id })
    }

    init(target: ConnectionProfile) {
        self.target = target
        _name = State(initialValue: target.name)
        _host = State(initialValue: target.host)
        _port = State(initialValue: String(target.port))
        _user = State(initialValue: target.user)
        _password = State(initialValue: "")
        _database = State(initialValue: target.database)
        _useTLS = State(initialValue: target.useTLS)
        _trustSelfSigned = State(initialValue: target.trustSelfSigned)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("基本信息") {
                    TextField("连接名称（可选）", text: $name)
                    TextField("主机 / IP", text: $host)
                        .textInputAutocapitalization(.never)
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                    TextField("用户名", text: $user)
                        .textInputAutocapitalization(.never)
                    SecureField("密码", text: $password)
                    TextField("默认数据库（可选）", text: $database)
                        .textInputAutocapitalization(.never)
                }
                Section("安全") {
                    Toggle("使用 TLS 加密连接", isOn: $useTLS)
                    if useTLS {
                        Toggle("信任自签名证书", isOn: $trustSelfSigned)
                            .foregroundColor(.secondary)
                    }
                }
                if let msg = testMessage {
                    Section { Text(msg).font(.footnote).foregroundColor(msg.contains("成功") ? .green : .red) }
                }
            }
            .navigationTitle(isNew ? "新建连接" : "编辑连接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await test() } } label: {
                        if testing { ProgressView() } else { Text("测试") }
                    }.disabled(testing)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { save() }.font(.headline)
                }
            }
            .onAppear {
                if store.profiles.contains(where: { $0.id == target.id }) {
                    // editing existing: prefill password from keychain
                    password = store.password(for: target)
                }
            }
        }
    }

    private func buildProfile() -> ConnectionProfile? {
        guard let p = Int(port), !host.isEmpty else { return nil }
        return ConnectionProfile(
            id: target.id,
            name: name.isEmpty ? host : name,
            host: host,
            port: p,
            user: user.isEmpty ? "root" : user,
            database: database,
            useTLS: useTLS,
            trustSelfSigned: trustSelfSigned
        )
    }

    private func save() {
        guard let prof = buildProfile() else {
            testMessage = "请填写主机并填写正确的端口"
            return
        }
        if store.profiles.contains(where: { $0.id == target.id }) {
            store.update(prof, password: password.isEmpty ? nil : password)
        } else {
            store.add(prof, password: password)
        }
        dismiss()
    }

    private func test() async {
        testing = true
        guard let prof = buildProfile() else {
            await MainActor.run { testMessage = "请填写主机并填写正确的端口" }
            await MainActor.run { testing = false }
            return
        }
        do {
            let conn = MySQLConnection(profile: prof)
            try await conn.connect(password: password)
            conn.close()
            await MainActor.run { testMessage = "连接成功 ✓" }
        } catch {
            let msg = "连接失败：\(error.localizedDescription)"
            await MainActor.run { testMessage = msg }
        }
        await MainActor.run { testing = false }
    }
}
