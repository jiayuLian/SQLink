import SwiftUI

/// 意见反馈页：收集用户建议 / 问题，提交到后端 /api/feedback。
/// 注意：本页仅从「我的」(ProfileView) 进入，而 ProfileView 仅在登录后可见，
/// 因此反馈天然绑定账号，后端可基于账号维度做防爆破限流。
struct FeedbackView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var content = ""
    @State private var contact = ""
    @State private var submitting = false
    @State private var submitted = false
    @State private var alertMsg: String?
    @State private var showAlert = false

    private let maxContent = 500
    private let maxContact = 100

    var body: some View {
        Form {
            Section {
                ZStack(alignment: .topLeading) {
                    if content.isEmpty {
                        Text("请描述你遇到的问题、建议或想说的话…")
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                    }
                    TextEditor(text: $content)
                        .frame(minHeight: 160)
                        .onChange(of: content) { newValue in
                            if newValue.count > maxContent {
                                content = String(newValue.prefix(maxContent))
                            }
                        }
                }
                HStack {
                    Spacer()
                    Text("\(content.count)/\(maxContent)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("反馈内容")
            } footer: {
                Text("提交内容会附带你的登录账号，便于我们跟进处理。")
                    .font(.caption)
            }

            Section {
                TextField("邮箱 / 微信（选填，便于回复）", text: $contact)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: contact) { newValue in
                        if newValue.count > maxContact {
                            contact = String(newValue.prefix(maxContact))
                        }
                    }
            } header: {
                Text("联系方式")
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    if submitting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("提交反馈")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(submitting || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if submitted {
                Section {
                    Label("已收到，感谢你的反馈！", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
        }
        .navigationTitle("意见反馈")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: $showAlert) {
            Button("确定") {}
        } message: {
            Text(alertMsg ?? "")
        }
    }

    private func submit() async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submitting = true
        defer { submitting = false }
        do {
            try await AuthService.shared.submitFeedback(
                baseURL: settings.apiBaseURL,
                token: settings.authToken,
                content: trimmed,
                contact: contact.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            await MainActor.run {
                submitted = true
                content = ""
                contact = ""
            }
        } catch {
            await MainActor.run {
                alertMsg = (error as? AuthError)?.errorDescription ?? error.localizedDescription
                showAlert = true
            }
        }
    }
}
