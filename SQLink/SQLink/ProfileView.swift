import SwiftUI

/// 「我的」页面：外观、查询设置、会员、分享、关于。
struct ProfileView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var showCopied = false
    @State private var showServerSheet = false
    @State private var showLogoutConfirm = false
    @State private var showImagePicker = false
    @State private var uploading = false
    @State private var avatarError: String?
    @State private var editingNickname = false
    @State private var nicknameDraft = ""
    @State private var showActivationSheet = false
    @State private var activationCode = ""
    @State private var activating = false
    @State private var activationMessage: String?

    private let appDownloadURL = "https://github.com/jiayuLian/SQLink/releases/tag/v1.0.7"
    private let authorWeChat = "cute6697"
    private let authorEmail = "lianjiayu998@163.com"

    var body: some View {
        NavigationView {
            Form {
                Section("外观") {
                    Picker("主题", selection: $settings.theme) {
                        ForEach(ThemeMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("查询设置") {
                    Toggle("自动保存上次 SQL（按数据表分别记忆）", isOn: $settings.autoSaveSQL)
                    Picker("默认每页显示条数", selection: $settings.pageSize) {
                        ForEach([50, 100, 200, 500], id: \.self) { s in
                            Text("\(s) 条").tag(s)
                        }
                    }
                }

                Section("账号") {
                    HStack(spacing: 14) {
                        AvatarView(urlString: settings.avatarURL, size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayName)
                                .font(.subheadline)
                                .lineLimit(1)
                            Button { showImagePicker = true } label: {
                                Label(uploading ? "上传中…" : "更换头像", systemImage: "camera")
                                    .font(.caption)
                            }
                            .disabled(uploading)
                        }
                        Spacer()
                    }
                    HStack {
                        Text("昵称")
                        Spacer()
                        if editingNickname {
                            TextField("昵称", text: $nicknameDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 180)
                            Button("保存") { saveNickname() }
                                .font(.caption)
                            Button("取消") { editingNickname = false; nicknameDraft = settings.nickname }
                                .font(.caption)
                        } else {
                            Text(settings.nickname.isEmpty ? "未设置" : settings.nickname)
                                .foregroundColor(.secondary)
                            Button("编辑") { nicknameDraft = settings.nickname; editingNickname = true }
                                .font(.caption)
                        }
                    }
                    if let err = avatarError {
                        Text(err).font(.caption).foregroundColor(.red)
                    }
                    Button { showServerSheet = true } label: { Label("服务器地址", systemImage: "network") }
                    Button(role: .destructive) { showLogoutConfirm = true } label: { Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right") }
                }

                Section("会员") {
                    HStack {
                        Text("当前版本")
                        Spacer()
                        Text(settings.isPro ? "会员版（全部功能开放）" : "免费版")
                            .foregroundColor(.secondary)
                    }
                    if !settings.isPro {
                        // App Store 合规：仅描述会员权益，不展示价格、不提供任何付款入口/收款码/外链。
                        // 会员通过在 App 外获取激活码后在下方「使用激活码」自助开通。
                        Text("会员专享：数据表编辑、全量数据查看与导出、无条数限制。")
                            .font(.caption).foregroundColor(.secondary)
                        Button { showActivationSheet = true } label: { Label("使用激活码开通会员", systemImage: "key") }
                        Button { copyWeChat() } label: { Label("联系客服（微信号：\(authorWeChat)）", systemImage: "bubble.left") }
                            .alert("已复制", isPresented: $showCopied) {
                                Button("确定") {}
                            } message: { Text("微信号 \(authorWeChat) 已复制到剪贴板，添加时请备注你的 App 昵称或注册邮箱，便于核对问题") }
                        if let mailURL = URL(string: "mailto:\(authorEmail)") {
                            Link("联系作者（邮箱：\(authorEmail)）", destination: mailURL)
                        }
                    } else {
                        Text("你当前已是会员，全部功能已开放。感谢支持！")
                            .font(.caption).foregroundColor(.secondary)
                        Button { showActivationSheet = true } label: { Label("使用激活码", systemImage: "key") }
                        Button { copyWeChat() } label: { Label("联系客服（微信号：\(authorWeChat)）", systemImage: "bubble.left") }
                            .alert("已复制", isPresented: $showCopied) {
                                Button("确定") {}
                            } message: { Text("微信号 \(authorWeChat) 已复制到剪贴板，添加时请备注你的 App 昵称或注册邮箱，便于核对问题") }
                        if let mailURL = URL(string: "mailto:\(authorEmail)") {
                            Link("联系作者（邮箱：\(authorEmail)）", destination: mailURL)
                        }
                    }
                }

                Section("分享") {
                    Button { ExportUtils.shareLink(appDownloadURL) } label: { Label("分享 App 给好友", systemImage: "square.and.arrow.up") }
                    Text("将通过系统分享面板打开，可分享到微信、朋友圈、QQ（若已安装），或存储到「文件」、AirDrop。")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("反馈与帮助") {
                    NavigationLink { FeedbackView() } label: {
                        Label("意见反馈", systemImage: "bubble.left.and.bubble.right")
                    }
                }

                Section("关于") {
                    HStack { Text("版本"); Spacer(); Text("1.0.7").foregroundColor(.secondary) }
                    if let url = URL(string: appDownloadURL) {
                        Link("开源仓库 / 更新日志", destination: url)
                    }
                }
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showServerSheet) {
                ServerURLSheet()
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(sourceType: .photoLibrary) { image in
                    uploadAvatar(image)
                }
            }
            .sheet(isPresented: $showActivationSheet) {
                ActivationSheet()
            }
            .alert("确认退出", isPresented: $showLogoutConfirm) {
                Button("取消", role: .cancel) {}
                Button("退出", role: .destructive) { settings.logout() }
            } message: {
                Text("退出后将回到登录页")
            }
        }
    }

    private func copyWeChat() {
        UIPasteboard.general.string = authorWeChat
        showCopied = true
    }

    private func saveNickname() {
        let trimmed = nicknameDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { editingNickname = false; return }
        Task {
            do {
                try await AuthService.shared.updateProfile(baseURL: settings.apiBaseURL, token: settings.authToken, nickname: trimmed)
                await MainActor.run {
                    settings.nickname = trimmed
                    editingNickname = false
                }
            } catch {
                await MainActor.run { activationMessage = error.localizedDescription }
            }
        }
    }

    private var displayName: String {
        if !settings.nickname.isEmpty { return settings.nickname }
        return settings.authEmail.isEmpty ? "未登录" : settings.authEmail
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

/// 激活码兑换弹窗：用户输入激活码，调用后端兑换 Pro 会员（年卡 / 永久卡）。
struct ActivationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settings: AppSettings
    @State private var code = ""
    @State private var activating = false
    @State private var message: String?
    @State private var success = false

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("输入激活码即可开通会员（支持年卡与永久卡）。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 16)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                TextField("激活码（如 SQLINK-Y-XXXX-XXXX）", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(.horizontal)
                if let message = message {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(success ? .accentColor : .red)
                        .padding(.horizontal)
                        .multilineTextAlignment(.center)
                }
                Button { redeem() } label: {
                    if activating {
                        ProgressView()
                    } else {
                        Label("激活", systemImage: "key")
                    }
                }
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || activating)
                Spacer()
            }
            .navigationTitle("激活会员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func redeem() {
        activating = true; message = nil
        Task {
            do {
                let data = try await AuthService.shared.redeemActivation(
                    baseURL: settings.apiBaseURL,
                    token: settings.authToken,
                    code: code
                )
                await MainActor.run {
                    settings.isPro = data.isPro
                    settings.proExpiresAt = data.expiresAt ?? ""
                    if let nickname = data.nickname { settings.nickname = nickname }
                    // 兑换成功后把最新会员状态固化到 iCloud Keychain（抗卸载/换机恢复）。
                    settings.syncCredentialsToKeychain()
                    success = true
                    activating = false
                    message = data.proType == "lifetime" ? "激活成功，已开通永久会员！" : "激活成功，已开通年卡会员！"
                }
            } catch {
                await MainActor.run {
                    success = false
                    message = error.localizedDescription
                    activating = false
                }
            }
        }
    }
}
