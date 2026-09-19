import SwiftUI

/// 「我的」页面：账号、外观、关于。
/// 交互：点头像 = 更换头像；点账号名称 = 弹出「账号操作」（修改密码 / 激活码开通会员 / 退出登录 / 注销账号）。
/// 登录态非强制：未登录或游客态（无 token）点击上述两处一律先引导登录，不发必然 401 的请求。
struct ProfileView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var showLogin = false
    @State private var showImagePicker = false
    @State private var uploading = false
    @State private var avatarError: String?
    @State private var confirmLogout = false
    @State private var showActivate = false
    @State private var activationCode = ""
    @State private var activating = false
    @State private var activationError: String?

    // 账号操作：点账号名称弹出（修改密码 / 激活码开通会员 / 退出登录 / 注销账号 / 取消）
    // 「取消」必须显式提供：不给的话系统会自动补一个英文 Cancel（原因见下方 confirmationDialog 处注释）。
    @State private var showAccountMenu = false
    @State private var showDeleteConfirm = false

    // 注销二次密码验证
    @State private var showDeletePassword = false
    @State private var deletePassword = ""
    @State private var showDeletePwd = false
    @State private var reauthing = false
    @State private var reauthError: String?

    // 修改密码（仅已登录态）：校验当前密码 → 重置为新密码 → 强制重新登录
    @State private var showChangePassword = false

    var body: some View {
        NavigationView {
            Form {
                // 1. 账号（置顶）
                Section("账号") {
                    HStack(spacing: 14) {
                        // 头像：点击直接进入更换头像。
                        // 点击区收窄为圆形（contentShape(Circle())），四个角不响应。
                        AvatarView(urlString: settings.avatarURL, size: 56)
                            .frame(width: 56, height: 56)
                            .clipShape(Circle())
                            .contentShape(Circle())
                            .onTapGesture { tapAvatar() }

                        // 账号名称区：点这里才弹出「账号操作」菜单。
                        VStack(alignment: .leading, spacing: 4) {
                            if settings.isLoggedIn {
                                Text(displayName)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                // 会员状态只显示这一处（图标在文字前）：
                                //   已登录 + 已开通 → 永久会员
                                //   已登录 + 未开通 → 免费用户
                                // 游客态（isLoggedIn 但无 token）不是真实账号，不显示会员标签，
                                // 改为引导登录；未登录态同理在下方显示「未登录」。
                                if settings.isPro {
                                    memberTag("永久会员", icon: "checkmark.seal.fill", color: .accentColor)
                                } else if !settings.authToken.isEmpty {
                                    memberTag("免费用户", icon: "seal", color: .secondary)
                                } else {
                                    Text("点击登录 / 注册").font(.caption).foregroundColor(.secondary)
                                }
                            } else {
                                Text("未登录").font(.subheadline)
                                Text("点击登录 / 注册").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        // 撑满剩余宽度 + 上下各 6pt，保证点击区不小于 44pt 的可用高度
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { tapAccount() }
                    }

                    // 头像下方的会员状态行已删除：会员/免费只显示在头像右侧一处，
                    // 避免同一个状态在同一个 Section 里出现两遍。
                    // 「修改密码」「激活码开通会员」等操作统一收进「账号操作」弹窗（点账号名称弹出）。
                    if settings.isLoggedIn {
                        // 上传中给个反馈：点头像会直接进相册，选完图若不提示会以为没反应
                        if uploading {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.7)
                                Text("正在上传头像…").font(.caption).foregroundColor(.secondary)
                            }
                        } else if let err = avatarError {
                            Text(err).font(.caption).foregroundColor(.red)
                        }
                    } else {
                        Button { showLogin = true } label: {
                            Label("登录 / 注册", systemImage: "person.crop.circle.badge.plus")
                        }
                    }
                }

                // 2. 外观（第二）
                Section("外观") {
                    Picker("主题", selection: $settings.theme) {
                        ForEach(ThemeMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // 关于我们（点进去查看版本 / 联系作者 / 意见反馈）
                Section("关于") {
                    NavigationLink { AboutView() } label: {
                        Label("关于我们", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showLogin) { AuthView(onDismiss: { showLogin = false }) }
            // 修改密码：走 POST /api/auth/change-password（需登录 + 校验当前密码）。
            // 取消只关弹窗；改成功才登出（后端会让旧 token 立即失效，必须用新密码重新登录）。
            .sheet(isPresented: $showChangePassword) {
                ChangePasswordView(
                    onCancel: { showChangePassword = false },
                    onDone: {
                        showChangePassword = false
                        settings.logout()
                    }
                )
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(sourceType: .photoLibrary) { image in
                    uploadAvatar(image)
                }
            }
            // 点账号名称弹出的「账号操作」：进入本弹窗的前提是 authToken 非空
            // （游客态 / 未登录会走登录页），所以「修改密码」天然只在真实登录后可见，
            // 与后端 /api/auth/change-password 的 authMiddleware 要求一致。
            // 「取消」必须显式写出来：confirmationDialog 底层是 UIAlertController(.actionSheet)，
            // 若按钮列表里没有 role: .cancel，系统会自动补一个 —— 而补出来的文案取系统语言，
            // 本 App 未声明本地化（Info.plist 缺 CFBundleLocalizations），实测补出来是英文「Cancel」。
            // 显式提供后系统就不再自行添加；点弹窗外遮罩依然能关闭，两者不冲突。
            // 会员无需「激活码开通会员」，故已是会员时该项不显示。
            .confirmationDialog("账号操作", isPresented: $showAccountMenu, titleVisibility: .visible) {
                Button("修改密码") { showChangePassword = true }
                if !settings.isPro {
                    Button("激活码开通会员") { showActivate = true }
                }
                Button("退出登录", role: .destructive) { confirmLogout = true }
                Button("注销账号", role: .destructive) { showDeleteConfirm = true }
                Button("取消", role: .cancel) {}
            }
            .alert("确认注销账号", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("确认注销", role: .destructive) { showDeletePassword = true }
            } message: {
                Text(deleteConfirmMessage)
            }
            // 注销二次密码验证：确认弹窗通过后，要求重新输入登录密码，
            // 校验通过（即本人操作）才真正调用删除接口。符合主流 App 防误删做法。
            .sheet(isPresented: $showDeletePassword) {
                NavigationView {
                    VStack(spacing: 18) {
                        Text("为确认是本人操作，请输入登录密码以完成注销。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        HStack {
                            PasswordField(text: $deletePassword, placeholder: "登录密码", showPassword: $showDeletePwd)
                                .frame(height: 44)
                            Button { showDeletePwd.toggle() } label: {
                                Image(systemName: showDeletePwd ? "eye.fill" : "eye.slash.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                        if let e = reauthError {
                            Text(e).foregroundColor(.red).font(.caption)
                        }
                        Button {
                            Task { await reauthenticateAndDelete() }
                        } label: {
                            HStack {
                                if reauthing { ProgressView().scaleEffect(0.8) }
                                Text("确认注销")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(deletePassword.trimmingCharacters(in: .whitespaces).isEmpty || reauthing)
                        Spacer()
                    }
                    .padding()
                    .navigationTitle("确认注销")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("取消") { resetDeleteFlow() }
                        }
                    }
                }
            }
            .alert("确认退出登录", isPresented: $confirmLogout) {
                Button("取消", role: .cancel) {}
                Button("退出", role: .destructive) { settings.logout() }
            } message: {
                Text("退出后需重新登录，本机登录态将被清除（如不想被重装后自动恢复，请先退出再卸载）")
            }
            .sheet(isPresented: $showActivate) {
                NavigationView {
                    VStack(spacing: 16) {
                        Text("输入激活码自助开通永久会员").font(.caption).foregroundColor(.secondary)
                        TextField("激活码", text: $activationCode)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        if let e = activationError {
                            Text(e).foregroundColor(.red).font(.caption)
                        }
                        Button {
                            Task { await redeemActivationCode() }
                        } label: {
                            HStack { if activating { ProgressView().scaleEffect(0.8) }; Text("开通会员") }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(activationCode.trimmingCharacters(in: .whitespaces).isEmpty || activating)
                        Spacer()
                    }
                    .padding()
                    .navigationTitle("开通会员")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("取消") { showActivate = false }
                        }
                    }
                }
            }
        }
    }

    /// 点头像 = 更换头像。
    /// 未登录 / 游客态（无 token）没有云端头像可换，且请求必带空 token → 401 会把游客态一起清掉，
    /// 所以统一先引导登录。
    private func tapAvatar() {
        if settings.authToken.isEmpty { showLogin = true }
        else { showImagePicker = true }
    }

    /// 点账号名称 = 弹出「账号操作」菜单（修改密码 / 激活码开通会员 / 退出登录 / 注销账号）。
    /// 同样地，无 token 时不进菜单，避免菜单里的请求触发 401 把游客态一起清掉。
    private func tapAccount() {
        if settings.authToken.isEmpty { showLogin = true }
        else { showAccountMenu = true }
    }

    private var displayName: String {
        // 游客态显示「游客模式」，与「未登录」（无任何登录态）区分开
        if settings.guestMode { return "游客模式" }
        return settings.authEmail.isEmpty ? "未登录" : settings.authEmail
    }

    /// 会员状态标签：图标与文字紧贴。
    /// 不用 `Label` —— `Label` 在 Form 行内的「图标—文字」间距由系统样式决定，实测偏大；
    /// 改用 HStack 显式指定 4pt，视觉上更紧凑。
    private func memberTag(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.caption)
        .foregroundColor(color)
    }

    /// 注销确认弹窗文案：若当前为会员，明确提示将失去会员权益且不予退还。
    private var deleteConfirmMessage: String {
        var msg = "注销后账号及云端数据（头像、反馈记录）将永久删除且无法恢复。"
        if settings.isPro {
            msg += "\n\n您当前为永久会员，注销后将立即失去会员权益且不予退还。"
        }
        msg += "\n\n点击「确认注销」后，还需输入登录密码确认。"
        return msg
    }

    /// 二次密码验证后注销：先用邮箱+密码重新登录确认是本人，成功后才真正删除云端账号。
    private func reauthenticateAndDelete() async {
        reauthing = true; reauthError = nil
        let email = settings.authEmail
        let pwd = deletePassword
        do {
            // 重新登录校验密码（仅用于确认身份，不更新本地登录态）
            _ = try await AuthService.shared.login(baseURL: settings.apiBaseURL, email: email, password: pwd)
            // 密码正确，执行注销
            try await AuthService.shared.deleteAccount(baseURL: settings.apiBaseURL, token: settings.authToken)
            await MainActor.run {
                reauthing = false
                showDeletePassword = false
                deletePassword = ""
                settings.logout()
            }
        } catch {
            await MainActor.run {
                reauthing = false
                reauthError = error.localizedDescription
            }
        }
    }

    /// 退出注销流程：清空所有相关状态。
    private func resetDeleteFlow() {
        showDeletePassword = false
        showDeleteConfirm = false
        deletePassword = ""
        reauthError = nil
    }

    private func redeemActivationCode() async {
        // 激活码绑定账号：未真实登录（游客态）不允许激活，避免带空 token 请求触发 401 强制登出
        guard !settings.authToken.isEmpty else {
            await MainActor.run { activationError = "请先登录账号后再使用激活码" }
            return
        }
        await MainActor.run { activating = true; activationError = nil }
        let code = activationCode.trimmingCharacters(in: .whitespaces)
        do {
            let data = try await AuthService.shared.redeemActivation(baseURL: settings.apiBaseURL, token: settings.authToken, code: code)
            await MainActor.run {
                settings.isPro = data.isPro
                settings.persistCredentials()
                activating = false
                showActivate = false
                activationCode = ""
            }
        } catch {
            await MainActor.run { activationError = error.localizedDescription; activating = false }
        }
    }

    private func uploadAvatar(_ image: UIImage) {
        uploading = true; avatarError = nil
        Task {
            do {
                guard let resized = image.resized(toMax: 512),
                      let data = resized.jpegData(compressionQuality: 0.8) else {
                    throw AuthError.message("图片处理失败")
                }
                let base64 = data.base64EncodedString()
                let url = try await AuthService.shared.uploadAvatar(
                    baseURL: settings.apiBaseURL,
                    token: settings.authToken,
                    imageBase64: base64,
                    ext: "jpg"
                )
                await MainActor.run {
                    settings.avatarURL = url + "?v=" + String(Int(Date().timeIntervalSince1970))
                    uploading = false
                }
            } catch {
                await MainActor.run { avatarError = error.localizedDescription; uploading = false }
            }
        }
    }
}

/// 圆形头像：有 URL 用 AsyncImage 加载，无则用系统人像占位。
struct AvatarView: View {
    let urlString: String
    let size: CGFloat

    var body: some View {
        Group {
            if !urlString.isEmpty, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color(.systemGray4), lineWidth: 1))
    }

    private var placeholder: some View {
        Image(systemName: "person.circle.fill")
            .resizable().scaledToFit()
            .foregroundColor(Color(.systemGray3))
            .padding(size * 0.12)
    }
}

/// 图片选择器（UIKit 包装，兼容 iOS 15）。
struct ImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.allowsEditing = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let img = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            if let img = img { parent.onImage(img) }
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

extension UIImage {
    func resized(toMax maxDimension: CGFloat) -> UIImage? {
        let longest = Swift.max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 0)
        draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }
}

/// 关于我们：版本、联系作者统一收纳于此，从「我的」点进去查看。
struct AboutView: View {
    private let authorWeChat = "cute6697"
    private let authorEmail = "lianjiayu998@163.com"
    @State private var copied = false

    var body: some View {
        Form {
            Section("版本") {
                HStack { Text("当前版本"); Spacer(); Text("1.0.10").foregroundColor(.secondary) }
            }
            Section("联系作者") {
                HStack {
                    Text("微信号")
                    Spacer()
                    Text(authorWeChat).foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    UIPasteboard.general.string = authorWeChat
                    copied = true
                }
                if let mailURL = URL(string: "mailto:\(authorEmail)") {
                    Link("邮箱：\(authorEmail)", destination: mailURL)
                }
            }
            Section("反馈") {
                NavigationLink { FeedbackView() } label: {
                    Label("意见反馈", systemImage: "bubble.left.and.bubble.right")
                }
            }
        }
        .navigationTitle("关于我们")
        .navigationBarTitleDisplayMode(.inline)
        .alert("已复制", isPresented: $copied) {
            Button("确定") {}
        } message: {
            Text("微信号 \(authorWeChat) 已复制，添加时请备注你的注册邮箱，便于核对问题")
        }
    }
}

/// 「修改密码」（已登录态）：输入当前密码校验身份 → 重置为新密码。
///
/// 入口在「我的」→ 点账号名称 → 「账号操作」弹窗里的「修改密码」，
/// 该弹窗只在 authToken 非空时才会出现（游客态 / 未登录点账号名称直接进登录页），
/// 即「只有登录成功之后才可以修改密码」在 UI 层与后端 authMiddleware 双重保证。
///
/// 为什么不再走邮箱验证码：后端已补齐 `POST /api/auth/change-password`，要求
/// Bearer token + 当前密码 —— 服务端强制，客户端绕不过去。
/// 邮箱验证码那条路仍保留在登录页的「找回密码」里（未登录 / 忘记密码时使用）。
/// 另外后端会让改密码之前签发的所有 token 立即失效，所以改完必须重新登录。
private struct ChangePasswordView: View {
    @EnvironmentObject var settings: AppSettings
    /// 取消：仅关闭弹窗，不动登录态。
    let onCancel: () -> Void
    /// 修改成功：关闭弹窗并强制重新登录。
    let onDone: () -> Void

    @State private var oldPassword = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var showPwd = false
    @State private var loading = false
    @State private var error: String?
    @State private var showDone = false

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text("为确认是本人操作，请输入当前密码。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Text(settings.authEmail)
                        .font(.footnote)
                        .foregroundColor(.primary)
                }

                HStack {
                    PasswordField(text: $oldPassword, placeholder: "当前密码", showPassword: $showPwd)
                        .frame(height: 44)
                    Button { showPwd.toggle() } label: {
                        Image(systemName: showPwd ? "eye.fill" : "eye.slash.fill")
                            .foregroundColor(.secondary)
                    }
                }
                HStack {
                    PasswordField(text: $password, placeholder: "新密码（至少 6 位）", showPassword: $showPwd)
                        .frame(height: 44)
                    Button { showPwd.toggle() } label: {
                        Image(systemName: showPwd ? "eye.fill" : "eye.slash.fill")
                            .foregroundColor(.secondary)
                    }
                }
                HStack {
                    PasswordField(text: $confirm, placeholder: "确认新密码", showPassword: $showPwd)
                        .frame(height: 44)
                    Button { showPwd.toggle() } label: {
                        Image(systemName: showPwd ? "eye.fill" : "eye.slash.fill")
                            .foregroundColor(.secondary)
                    }
                }

                if let error = error {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }

                Button { submit() } label: {
                    HStack {
                        if loading { ProgressView().scaleEffect(0.8) }
                        Text("确认修改")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading || oldPassword.isEmpty || password.count < 6 || confirm.isEmpty)

                Text("忘记当前密码？请退出登录后，在登录页使用「找回密码」（邮箱验证码）。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding()
            .navigationTitle("修改密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { onCancel() }
                }
            }
        }
        .alert("修改成功", isPresented: $showDone) {
            Button("重新登录") { onDone() }
        } message: {
            Text("密码已更新，请使用新密码重新登录。")
        }
    }

    private func submit() {
        guard password == confirm else { error = "两次输入的新密码不一致"; return }
        guard password.count >= 6 else { error = "新密码至少 6 位"; return }
        guard password != oldPassword else { error = "新密码不能与当前密码相同"; return }
        // 兜底：无 token 时不该出现这个入口，但仍防御一下，避免发出必然 401 的请求把游客态也清掉。
        guard !settings.authToken.isEmpty else { error = "登录态已失效，请重新登录后再试"; return }
        loading = true; error = nil
        Task {
            do {
                try await AuthService.shared.changePassword(
                    baseURL: settings.apiBaseURL,
                    token: settings.authToken,
                    oldPassword: oldPassword,
                    newPassword: password
                )
                await MainActor.run { loading = false; showDone = true }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; self.loading = false }
            }
        }
    }
}

