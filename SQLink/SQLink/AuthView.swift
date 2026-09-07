import SwiftUI

/// 登录 / 注册 / 找回密码 三态视图
struct AuthView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var mode: AuthMode = .login

    enum AuthMode: String, CaseIterable, Identifiable {
        case login = "登录"
        case register = "注册"
        case forgot = "找回密码"
        var id: String { rawValue }
        var label: String { rawValue }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("模式", selection: $mode) {
                    ForEach(AuthMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                Group {
                    switch mode {
                    case .login: LoginForm()
                    case .register: RegisterForm(onRegistered: { mode = .login })
                    case .forgot: ForgotPasswordForm(onDone: { mode = .login })
                    }
                }
                .padding(.horizontal)

                Spacer()

                Button { settings.enterGuestMode() } label: {
                    Text("游客模式（功能受限）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 8)
            }
            .navigationTitle("SQLink 账号")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct LoginForm: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            TextField("邮箱", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)

            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)

            if let error = error {
                Text(error).foregroundColor(.red).font(.caption)
            }

            Button { login() } label: {
                HStack {
                    if loading { ProgressView().scaleEffect(0.8) }
                    Text("登录")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(loading || email.isEmpty || password.isEmpty)
        }
    }

    private func login() {
        loading = true; error = nil
        Task {
            do {
                let result = try await AuthService.shared.login(baseURL: settings.apiBaseURL, email: email, password: password)
                await MainActor.run {
                    settings.applyMembership(result.email, token: result.token, isPro: result.isPro, expiresAt: result.expiresAt ?? "")
                    loading = false
                    dismiss()
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; self.loading = false }
            }
        }
    }
}

private struct RegisterForm: View {
    @EnvironmentObject var settings: AppSettings
    let onRegistered: () -> Void
    @State private var email = ""
    @State private var code = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var loading = false
    @State private var sending = false
    @State private var error: String?
    @State private var devCode: String?
    @State private var showCodeAlert = false
    @State private var countdown = 0

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                TextField("邮箱", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)
                Button { sendCode() } label: {
                    Text(sending ? "发送中…" : (countdown > 0 ? "\(countdown)s 后重发" : (devCode != nil ? "已获取" : "获取验证码")))
                }
                .disabled(sending || email.isEmpty || countdown > 0)
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                if countdown > 0 { countdown -= 1 }
            }

            TextField("验证码", text: $code)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)

            SecureField("密码（至少 6 位）", text: $password)
                .textFieldStyle(.roundedBorder)

            SecureField("确认密码", text: $confirm)
                .textFieldStyle(.roundedBorder)

            if let error = error {
                Text(error).foregroundColor(.red).font(.caption)
            }

            Button { register() } label: {
                HStack {
                    if loading { ProgressView().scaleEffect(0.8) }
                    Text("注册")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(loading || email.isEmpty || code.isEmpty || password.count < 6)
        }
        .alert("测试验证码", isPresented: $showCodeAlert) {
            Button("确定") {}
        } message: {
            Text("后端未配置 SMTP，本次验证码为：\(devCode ?? "")")
        }
    }

    private func sendCode() {
        sending = true; error = nil; devCode = nil
        Task {
            do {
                let code = try await AuthService.shared.sendRegisterCode(baseURL: settings.apiBaseURL, email: email)
                await MainActor.run {
                    sending = false
                    countdown = 60
                    if let c = code {
                        devCode = c
                        showCodeAlert = true
                    }
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; self.sending = false }
            }
        }
    }

    private func register() {
        guard password == confirm else { error = "两次输入的密码不一致"; return }
        loading = true; error = nil
        Task {
            do {
                let result = try await AuthService.shared.register(baseURL: settings.apiBaseURL, email: email, code: code, password: password)
                await MainActor.run {
                    settings.applyMembership(result.email, token: result.token, isPro: result.isPro, expiresAt: result.expiresAt ?? "")
                    loading = false
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; self.loading = false }
            }
        }
    }
}

private struct ForgotPasswordForm: View {
    @EnvironmentObject var settings: AppSettings
    let onDone: () -> Void
    @State private var email = ""
    @State private var code = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var sending = false
    @State private var loading = false
    @State private var error: String?
    @State private var devCode: String?
    @State private var showCodeAlert = false
    @State private var showDone = false
    @State private var countdown = 0

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                TextField("邮箱", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)
                Button { sendCode() } label: { Text(sending ? "发送中…" : (countdown > 0 ? "\(countdown)s 后重发" : (devCode != nil ? "已获取" : "获取验证码"))) }
                    .disabled(sending || email.isEmpty || countdown > 0)
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                if countdown > 0 { countdown -= 1 }
            }

            TextField("验证码", text: $code)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)

            SecureField("新密码（至少 6 位）", text: $password)
                .textFieldStyle(.roundedBorder)

            SecureField("确认新密码", text: $confirm)
                .textFieldStyle(.roundedBorder)

            if let error = error {
                Text(error).foregroundColor(.red).font(.caption)
            }

            Button { reset() } label: {
                HStack {
                    if loading { ProgressView().scaleEffect(0.8) }
                    Text("重置密码")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(loading || email.isEmpty || code.isEmpty || password.count < 6)
        }
        .alert("测试验证码", isPresented: $showCodeAlert) {
            Button("确定") {}
        } message: {
            Text("后端未配置 SMTP，本次验证码为：\(devCode ?? "")")
        }
        .alert("重置成功", isPresented: $showDone) {
            Button("去登录") { onDone() }
        } message: {
            Text("请使用新密码登录")
        }
    }

    private func sendCode() {
        sending = true; error = nil; devCode = nil
        Task {
            do {
                let code = try await AuthService.shared.sendResetCode(baseURL: settings.apiBaseURL, email: email)
                await MainActor.run {
                    sending = false
                    countdown = 60
                    if let c = code {
                        devCode = c
                        showCodeAlert = true
                    }
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; self.sending = false }
            }
        }
    }

    private func reset() {
        guard password == confirm else { error = "两次输入的密码不一致"; return }
        loading = true; error = nil
        Task {
            do {
                try await AuthService.shared.resetPassword(baseURL: settings.apiBaseURL, email: email, code: code, password: password)
                await MainActor.run { loading = false; showDone = true }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; self.loading = false }
            }
        }
    }
}
