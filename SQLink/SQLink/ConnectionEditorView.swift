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
    @State private var testMessage: String?
    @State private var testing = false
    @State private var showPwd = false

    private var isNew: Bool {
        !store.profiles.contains(where: { $0.id == target.id })
    }

    /// 提示文案里带「成功」即视为通过（沿用原判断，避免再加一个状态位）。
    private var testOK: Bool {
        testMessage?.contains("成功") ?? false
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
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 测试结果固定在表单上方：点「测试」时用户往往正滚在页面中间或底部，
                // 结果放 Form 末尾（原来的写法）根本看不见，只能一路滑到底。
                if let msg = testMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.system(size: 16))
                            .foregroundColor(testOK ? .green : .red)
                        Text(msg)
                            .font(.footnote)
                            .foregroundColor(testOK ? .green : .red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            testMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background((testOK ? Color.green : Color.red).opacity(0.12))
                }
                Form {
                    Section("基本信息") {
                        TextField("连接名称（可选）", text: $name)
                        TextField("主机 / IP", text: $host)
                            .textInputAutocapitalization(.never)
                        TextField("端口", text: $port)
                            .keyboardType(.numberPad)
                        TextField("用户名", text: $user)
                            .textInputAutocapitalization(.never)
                        HStack {
                            PasswordField(text: $password, placeholder: "密码", showPassword: $showPwd)
                            Button { showPwd.toggle() } label: {
                                Image(systemName: showPwd ? "eye.fill" : "eye.slash.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                        TextField("默认数据库（可选）", text: $database)
                            .textInputAutocapitalization(.never)
                    }
                    Section("安全") {
                        Toggle("使用 SSL 连接", isOn: $useTLS)
                        Text("已启用加密传输，并自动信任自签名证书（适用于自建服务器）。关闭后将使用明文连接。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
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
            .onChange(of: formSignature) { _ in
                // 改了参数就把旧结果收掉，别让「连接成功」一直挂在那里误导人
                if testMessage != nil { testMessage = nil }
            }
        }
    }

    /// 表单内容签名：任一字段变化就清掉上一次的测试结果，避免「改了参数还显示上次连接成功」。
    private var formSignature: String {
        "\(host)|\(port)|\(user)|\(password)|\(database)|\(useTLS)"
    }

    private func buildProfile() -> ConnectionProfile? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, let p = Int(port.trimmingCharacters(in: .whitespaces)) else { return nil }
        // 端口必须落在 1–65535，否则会发给系统一个非法端口（表现为「连接失败」但原因难懂）
        guard (1...65535).contains(p) else { return nil }
        return ConnectionProfile(
            id: target.id,
            name: name.isEmpty ? trimmedHost : name,
            host: trimmedHost,
            port: p,
            user: user.isEmpty ? "root" : user,
            database: database.trimmingCharacters(in: .whitespacesAndNewlines),
            useTLS: useTLS,
            trustSelfSigned: useTLS
        )
    }

    private func save() {
        guard let prof = buildProfile() else {
            testMessage = "请填写主机，并填写 1–65535 之间的端口"
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
            await MainActor.run {
                testMessage = "请填写主机，并填写 1–65535 之间的端口"
                testing = false
            }
            return
        }
        do {
            let conn = MySQLConnection(profile: prof)
            try await conn.connect(password: password)
            conn.close()
            await MainActor.run { testMessage = "连接成功 ✓" }
        } catch {
            // MySQLError 的 errorDescription 自带「连接失败：」前缀，再拼一次会变成
            // 「连接失败：连接失败：…」；只有未带前缀的底层错误才补。
            let desc = error.localizedDescription
            let msg = desc.hasPrefix("连接失败") ? desc : "连接失败：\(desc)"
            await MainActor.run { testMessage = msg }
        }
        await MainActor.run { testing = false }
    }
}
