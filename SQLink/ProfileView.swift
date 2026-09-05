import SwiftUI

/// 「我的」页面：外观、查询设置、会员、分享、关于。
struct ProfileView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var showCopied = false
    @State private var showQRSheet = false
    @State private var qrImageName = ""
    @State private var qrTitle = ""
    @State private var refreshing = false
    @State private var refreshError: String?
    @State private var showServerSheet = false
    @State private var showLogoutConfirm = false
    @State private var showImagePicker = false
    @State private var uploading = false
    @State private var avatarError: String?

    private let appDownloadURL = "https://github.com/jiayuLian/SQLink/releases/tag/v1.0.4"
    private let authorWeChat = "cute6697"

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
                            Text(settings.authEmail.isEmpty ? "未登录" : settings.authEmail)
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
                    if let err = avatarError {
                        Text(err).font(.caption).foregroundColor(.red)
                    }
                    HStack {
                        Button { refreshMembership() } label: {
                            Label(refreshing ? "刷新中…" : "刷新会员状态", systemImage: "arrow.clockwise")
                        }
                        .disabled(refreshing)
                        Spacer()
                        if let err = refreshError {
                            Text(err).font(.caption).foregroundColor(.red)
                        }
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
                        // 价格来自后端配置（settings.plan），可随时调整，无需发版
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("开通会员").font(.subheadline).fontWeight(.medium)
                            Spacer()
                            Text("\(settings.plan.currency)\(settings.plan.proPriceYearly)/年 或 \(settings.plan.currency)\(settings.plan.proPriceLifetime)永久")
                                .font(.subheadline).foregroundColor(.accentColor)
                        }
                        Text("免费版权益：查看上限 \(settings.plan.freeViewLimit) 条、导出上限 \(settings.plan.freeExportLimit) 条；数据编辑、全量导出、无限查看需会员。")
                            .font(.caption).foregroundColor(.secondary)
                        Button { showQR(name: "wechat_add_qr", title: "添加作者微信") } label: { Label("添加作者微信", systemImage: "qrcode") }
                        Button { showQR(name: "wechat_pay_qr", title: "微信支付收款码") } label: { Label("扫码开通会员", systemImage: "dollarsign.circle") }
                    } else {
                        Text("你当前已是会员，全部功能已开放。感谢支持！")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Button { copyWeChat() } label: { Label("复制微信号：\(authorWeChat)", systemImage: "doc.on.doc") }
                        .alert("已复制", isPresented: $showCopied) {
                            Button("确定") {}
                        } message: { Text("微信号 \(authorWeChat) 已复制到剪贴板") }
                }

                Section("分享") {
                    Button { ExportUtils.shareLink(appDownloadURL) } label: { Label("分享 App 给好友", systemImage: "square.and.arrow.up") }
                    Text("将通过系统分享面板打开，可分享到微信、朋友圈、QQ（若已安装），或存储到「文件」、AirDrop。")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("关于") {
                    HStack { Text("版本"); Spacer(); Text("1.0.4").foregroundColor(.secondary) }
                    if let url = URL(string: appDownloadURL) {
                        Link("开源仓库 / 更新日志", destination: url)
                    }
                }
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showQRSheet) {
                QRCodeSheet(imageName: qrImageName, title: qrTitle)
            }
            .sheet(isPresented: $showServerSheet) {
                ServerURLSheet()
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(sourceType: .photoLibrary) { image in
                    uploadAvatar(image)
                }
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

    private func showQR(name: String, title: String) {
        qrImageName = name
        qrTitle = title
        showQRSheet = true
    }

    private func refreshMembership() {
        refreshing = true; refreshError = nil
        Task {
            do {
                let data = try await AuthService.shared.fetchMembership(baseURL: settings.apiBaseURL, token: settings.authToken)
                await MainActor.run {
                    if let email = data.email { settings.authEmail = email }
                    settings.isPro = data.isPro
                    settings.avatarURL = data.avatar ?? ""
                    refreshing = false
                }
            } catch {
                await MainActor.run { refreshError = error.localizedDescription; refreshing = false }
            }
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
    func resized(toMax max: CGFloat) -> UIImage? {
        let longest = max(size.width, size.height)
        guard longest > max else { return self }
        let scale = max / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 0)
        draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }
}

/// 二维码大图 + 长按保存到相册。
struct QRCodeSheet: View {
    let imageName: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var showSaved = false

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Text("截图或长按保存到相册，然后在微信中识别")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 16)

                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 280)
                    .cornerRadius(12)
                    .contextMenu {
                        Button { saveImage() } label: { Label("保存到相册", systemImage: "square.and.arrow.down") }
                    }
                    .onLongPressGesture {
                        saveImage()
                    }

                Text("微信号：cute6697")
                    .font(.headline)

                Spacer()
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { saveImage() } label: { Label("保存", systemImage: "square.and.arrow.down") }
                }
            }
            .alert("已保存", isPresented: $showSaved) {
                Button("确定") {}
            } message: {
                Text("二维码已保存到相册")
            }
        }
    }

    private func saveImage() {
        guard let uiImage = UIImage(named: imageName) else { return }
        UIImageWriteToSavedPhotosAlbum(uiImage, nil, nil, nil)
        showSaved = true
    }
}
