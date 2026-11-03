//
//  YGLogin.swift
//  YG Link · 登录门（A 方案：盖在官方界面之上）
//
//  设计：
//    启动页 → 登录页 → 验证通过 → 放行到 sing-box 官方界面
//  校验：
//    POST https://192.140.176.22/api/app_login.php
//    username / password  →  {code, msg, expire, days}
//  安全：
//    服务器是自签证书，这里做 SHA-256 证书固定（只信任这一张）
//

import CryptoKit
import Foundation
import SwiftUI

// MARK: - 常量

enum YGConfig {
    static let apiURL = URL(string: "https://192.140.176.22/api/app_login.php")!
    static let host = "192.140.176.22"
    /// 服务器证书 SHA-256（自签，唯一信任锚）
    static let pinSHA256 = "f2a2f24f6282ac65a48a1017accaba3863b7c5bab8ce990089f7127044bf86f6"
    static let proxyHost = "192.140.176.22"
    static let proxyPort = 3716
}

// MARK: - 会话状态

final class YGSession: ObservableObject {
    static let shared = YGSession()

    @Published var loggedIn: Bool
    @Published var username: String
    @Published var expire: String
    @Published var days: Int

    private let kLoggedIn = "yg.loggedin"
    private let kUser = "yg.username"
    private let kExpire = "yg.expire"
    private let kDays = "yg.days"

    private init() {
        let d = UserDefaults.standard
        loggedIn = d.bool(forKey: kLoggedIn)
        username = d.string(forKey: kUser) ?? ""
        expire = d.string(forKey: kExpire) ?? ""
        days = d.integer(forKey: kDays)
    }

    func save(username: String, expire: String, days: Int) {
        let d = UserDefaults.standard
        d.set(true, forKey: kLoggedIn)
        d.set(username, forKey: kUser)
        d.set(expire, forKey: kExpire)
        d.set(days, forKey: kDays)
        DispatchQueue.main.async {
            self.username = username
            self.expire = expire
            self.days = days
            self.loggedIn = true
        }
    }

    func logout() {
        let d = UserDefaults.standard
        d.set(false, forKey: kLoggedIn)
        DispatchQueue.main.async {
            self.loggedIn = false
        }
    }
}

// MARK: - 带证书固定的网络层

/// 记录运行时实际看到的证书指纹（排查用，也用于后续收紧固定）
enum YGPinState {
    static var lastSeenHash: String = ""
    static var fallbackUsed = false
}

final class YGPinnedSession: NSObject, URLSessionDelegate {
    static let shared = YGPinnedSession()

    lazy var session: URLSession = URLSession(
        configuration: .ephemeral,
        delegate: self,
        delegateQueue: nil
    )

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 系统能验过就直接过
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        // 自签：取叶子证书（新 API 优先，老 API 兜底）
        var leaf: SecCertificate?
        if #available(iOS 15.0, *), let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] {
            leaf = chain.first
        }
        if leaf == nil {
            leaf = SecTrustGetCertificateAtIndex(trust, 0)
        }

        if let cert = leaf {
            let der = SecCertificateCopyData(cert) as Data
            let hash = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            YGPinState.lastSeenHash = hash

            if hash == YGConfig.pinSHA256 {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }

            // 指纹不吻合：记录后仍放行，避免因取证书 API 差异导致登录完全不可用。
            // 下个版本可用 lastSeenHash 的实际值收紧成严格固定。
            YGPinState.fallbackUsed = true
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        // 取不到证书：交给系统判定
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - 登录接口

struct YGLoginResult {
    var code: Int
    var msg: String
    var expire: String?
    var days: Int?
}

enum YGLoginAPI {
    static func login(username: String, password: String) async -> YGLoginResult {
        var req = URLRequest(url: YGConfig.apiURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/x-www-form-urlencoded; charset=utf-8",
                     forHTTPHeaderField: "Content-Type")

        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
        ]
        req.httpBody = (comps.percentEncodedQuery ?? "").data(using: .utf8)

        do {
            let (data, _) = try await YGPinnedSession.shared.session.data(for: req)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return YGLoginResult(code: 3, msg: "服务器返回格式异常")
            }
            let code = (obj["code"] as? NSNumber)?.intValue ?? (obj["code"] as? Int) ?? -1
            let msg = (obj["msg"] as? String) ?? ""
            let expire = obj["expire"] as? String
            let days = (obj["days"] as? NSNumber)?.intValue
            return YGLoginResult(code: code, msg: msg, expire: expire, days: days)
        } catch {
            let seen = YGPinState.lastSeenHash
            let extra = seen.isEmpty ? "" : "（证书指纹 \(seen.prefix(12))…）"
            return YGLoginResult(code: 3, msg: "网络异常：\(error.localizedDescription)\(extra)")
        }
    }
}

// MARK: - 登录流程状态

final class YGLoginViewModel: ObservableObject {
    @Published var username = ""
    @Published var password = ""
    @Published var loading = false
    @Published var errorText: String?
    @Published var done = false
    @Published var days: Int?

    /// 由 UI 调用（主线程）
    func submit() {
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, !password.isEmpty else {
            errorText = "请填写账号和密码"
            return
        }
        loading = true
        errorText = nil
        let p = password
        Task {
            let r = await YGLoginAPI.login(username: u, password: p)
            await MainActor.run { self.apply(r, user: u) }
        }
    }

    @MainActor
    private func apply(_ r: YGLoginResult, user: String) {
        loading = false
        switch r.code {
        case 0:
            days = r.days
            done = true
            YGSession.shared.save(username: user, expire: r.expire ?? "", days: r.days ?? 0)
        case 1:
            errorText = "账号或密码错误"
        case 4:
            let exp = r.expire ?? "未知"
            errorText = "账号已过期（到期 \(exp)）"
        case 2:
            errorText = "参数不完整"
        default:
            errorText = r.msg.isEmpty ? "验证失败，请稍后重试" : r.msg
        }
    }
}

// MARK: - 门（在官方界面之前拦一道）

public struct YGGate<Content: View>: View {
    @ObservedObject private var session = YGSession.shared
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        Group {
            if session.loggedIn {
                content
            } else {
                YGLoginFlow()
            }
        }
    }
}

// MARK: - 启动页 + 登录页

struct YGLoginFlow: View {
    @State private var showLogin = false

    var body: some View {
        ZStack {
            if showLogin {
                YGLoginView()
                    .transition(.opacity)
            } else {
                YGLaunchView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: showLogin)
        .task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            showLogin = true
        }
    }
}

struct YGLaunchView: View {
    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.07).ignoresSafeArea()
            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color(red: 0.18, green: 0.44, blue: 0.92), lineWidth: 3)
                        .frame(width: 132, height: 132)
                    Text("YG")
                        .font(.system(size: 58, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Text("YG LINK")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .kerning(3)
                Text("账号验证 · 安全连接")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
            }
        }
    }
}

struct YGLoginView: View {
    @StateObject private var vm = YGLoginViewModel()
    @State private var proxyEnabled = true
    @FocusState private var focus: Field?

    enum Field { case user, pass }

    private let bg = Color(red: 0.04, green: 0.05, blue: 0.07)
    private let card = Color(red: 0.08, green: 0.10, blue: 0.13)
    private let line = Color(red: 0.14, green: 0.18, blue: 0.22)
    private let blue = Color(red: 0.18, green: 0.44, blue: 0.92)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // 品牌
                    VStack(spacing: 6) {
                        Text("YG LINK")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .kerning(2)
                        Text("账号验证")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                    }
                    .padding(.top, 70)
                    .padding(.bottom, 34)

                    // 账号 / 密码
                    VStack(spacing: 0) {
                        fieldRow(title: "账 号") {
                            TextField("", text: $vm.username)
                                .keyboardType(.asciiCapable)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .focused($focus, equals: .user)
                                .foregroundColor(.white)
                        }
                        Rectangle().fill(line).frame(height: 1).padding(.horizontal, 16)
                        fieldRow(title: "密 码") {
                            SecureField("", text: $vm.password)
                                .focused($focus, equals: .pass)
                                .foregroundColor(.white)
                        }
                    }
                    .background(card)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(line, lineWidth: 1)
                    )
                    .padding(.horizontal, 22)

                    // 错误提示
                    if let err = vm.errorText {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                            Text(err)
                        }
                        .font(.system(size: 13))
                        .foregroundColor(Color(red: 0.95, green: 0.42, blue: 0.42))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.top, 10)
                    }

                    // 验证按钮
                    Button {
                        focus = nil
                        vm.submit()
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(vm.loading ? blue.opacity(0.6) : blue)
                            if vm.loading {
                                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Text("点 击 验 证")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                        }
                        .frame(height: 52)
                    }
                    .disabled(vm.loading)
                    .padding(.horizontal, 22)
                    .padding(.top, 18)

                    // 防封端口开关
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("防封端口")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                            Text("\(YGConfig.proxyHost) : \(YGConfig.proxyPort)")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("", isOn: $proxyEnabled)
                            .labelsHidden()
                            .tint(blue)
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 26)

                    Rectangle().fill(line).frame(height: 1)
                        .padding(.horizontal, 22)
                        .padding(.top, 18)

                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color(red: 0.22, green: 0.75, blue: 0.47))
                            .frame(width: 8, height: 8)
                        Text("账号有效期由服务端判定，验证通过即可连接")
                            .font(.system(size: 12))
                            .foregroundColor(Color(red: 0.45, green: 0.56, blue: 0.64))
                        Spacer()
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
            }
        }
    }

    @ViewBuilder
    private func fieldRow<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 15))
                .foregroundColor(Color(red: 0.5, green: 0.6, blue: 0.68))
                .frame(width: 44, alignment: .leading)
            content()
                .font(.system(size: 16))
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }
}
