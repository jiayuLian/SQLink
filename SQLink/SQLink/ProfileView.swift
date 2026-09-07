import SwiftUI

/// 「我的」页面：账号、外观、反馈与帮助、关于。
/// 登录态非强制：未登录时仅显示登录入口；点击头像/账号可跳转登录或选择头像。
struct ProfileView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var showLogin = false
    @State private var showImagePicker = false
    @State private var uploading = false
    @State private var avatarError: String?
    @State private var confirmLogout = false
    @State private var refreshing = false
    @State private var showActivate = false
    @State private var activationCode = ""
    @State private var activating = false
    @State private var activationError: String?

    // 账号操作：点击账号区弹出（更换头像 / 退出登录 / 注销账号）
    @State private var showAccountMenu = false
    @State private var showDeleteConfirm = false
    @State private var showDeleteError = false
    @State private var deleting = false
    @State private var deleteError: String?

    private let authorWeChat = "cute6697"
    private let authorEmail = "lianjiayu998@163.com"

    var body: some View {
        NavigationView {
            Form {
                // 1. 账号（置顶）
                Section("账号") {
                    HStack(spacing: 14) {
                        AvatarView(urlString: settings.avatarURL, size: 56)
                            .frame(width: 56, height: 56)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            if settings.isLoggedIn {
                                Text(displayName)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                if !settings.isPro {
                                    Text("免费版").font(.caption).foregroundColor(.secondary)
                                } else if settings.proExpiresAt.isEmpty {
                                    Text("永久会员").font(.caption).foregroundColor(.accentColor)
                                } else {
                                    Text("会员版 · 到期 \(formatExpiry(settings.proExpiresAt))")
                                        .font(.caption).foregroundColor(.accentColor)
                                }
                            } else {
                                Text("未登录").font(.subheadline)
                                Text("点击登录 / 注册").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if settings.isLoggedIn { showAccountMenu = true }
                        else { showLogin = true }
                    }

                    if settings.isLoggedIn {
                        if let err = avatarError {
                            Text(err).font(.caption).foregroundColor(.red)
                        }
                        // 会员区：非会员可激活码开通，会员可刷新状态
                        if settings.isPro {
                            HStack {
                                Label("会员状态", systemImage: "checkmark.seal.fill")
                                    .foregroundColor(.accentColor)
                                Spacer()
                                if refreshing {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    Button { Task { await refreshProStatus() } } label: {
                                        Label("刷新状态", systemImage: "arrow.clockwise").font(.caption)
                                    }
                                }
                            }
                        } else {
                            Button { showActivate = true } label: {
                                Label("激活码开通会员", systemImage: "key.fill")
                            }
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
            .sheet(isPresented: $showLogin) { AuthView() }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(sourceType: .photoLibrary) { image in
                    uploadAvatar(image)
                }
            }
            .confirmationDialog("账号操作", isPresented: $showAccountMenu, titleVisibility: .visible) {
                Button("更换头像") { showImagePicker = true }
                Button("退出登录", role: .destructive) { confirmLogout = true }
                Button("注销账号", role: .destructive) { showDeleteConfirm = true }
                Button("取消", role: .cancel) {}
            }
            .alert("确认注销账号", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("确认注销", role: .destructive) { Task { await deleteAccount() } }
            } message: {
                Text("注销后账号及云端数据（头像、反馈记录）将永久删除且无法恢复，确定要继续吗？")
            }
            .alert("注销失败", isPresented: $showDeleteError) {
                Button("确定") {}
            } message: {
                Text(deleteError ?? "未知错误")
            }
            .alert("确认退出登录", isPresented: $confirmLogout) {
                Button("取消", role: .cancel) {}
                Button("退出", role: .destructive) { settings.logout() }
            } message: {
                Text("退出后需重新登录，本机登录态将被清除（如不想被重装后自动恢复，请先退出再卸载）")
            }
            .overlay {
                if deleting {
                    ZStack {
                        Color.black.opacity(0.28).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在注销账号…").font(.caption).foregroundColor(.white)
                        }
                        .padding(22)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(14)
                        .shadow(radius: 8)
                    }
                    .ignoresSafeArea()
                }
            }
            .disabled(deleting)
            .sheet(isPresented: $showActivate) {
                NavigationView {
                    VStack(spacing: 16) {
                        Text("输入激活码自助开通会员（年卡 / 永久卡）").font(.caption).foregroundColor(.secondary)
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

    private var proLabel: String {
        settings.proExpiresAt.isEmpty ? "永久会员" : "会员版"
    }

    private var displayName: String {
        settings.authEmail.isEmpty ? "未登录" : settings.authEmail
    }

    /// 未登录 → 跳登录；已登录 → 选头像（无「更换头像」文字，直接调相册）。
    private func refreshProStatus() async {
        refreshing = true
        await settings.refreshMembership()
        await MainActor.run { refreshing = false }
    }

    /// 注销账号：删除云端账号与数据后清除本地登录态。
    private func deleteAccount() async {
        deleting = true; deleteError = nil
        do {
            try await AuthService.shared.deleteAccount(baseURL: settings.apiBaseURL, token: settings.authToken)
            await MainActor.run {
                deleting = false
                settings.logout()
            }
        } catch {
            await MainActor.run { deleteError = error.localizedDescription; deleting = false; showDeleteError = true }
        }
    }

    private func redeemActivationCode() async {
        activating = true; activationError = nil
        let code = activationCode.trimmingCharacters(in: .whitespaces)
        do {
            let data = try await AuthService.shared.redeemActivation(baseURL: settings.apiBaseURL, token: settings.authToken, code: code)
            await MainActor.run {
                settings.isPro = data.isPro
                settings.proExpiresAt = data.expiresAt ?? ""
                settings.persistCredentials()
                activating = false
                showActivate = false
                activationCode = ""
            }
        } catch {
            await MainActor.run { activationError = error.localizedDescription; activating = false }
        }
    }

    private func formatExpiry(_ s: String) -> String {
        let s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "" }
        let out = DateFormatter(); out.dateFormat = "yyyy-MM-dd"
        if let d = ISO8601DateFormatter().date(from: s) { return out.string(from: d) }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        if let d = f.date(from: s) { return out.string(from: d) }
        return String(s.prefix(10))
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

