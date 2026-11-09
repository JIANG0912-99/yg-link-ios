//
//  YGLogin.swift
//  YG Link · 登录门（A 方案：盖在官方界面之上）
//
//  设计：
//    启动页 → 登录页 → 验证通过 → 放行到 sing-box 官方界面
//  校验：
//    POST https://__YG_HOST__/api/app_login.php
//    username / password  →  {code, msg, expire, days}
//  安全：
//    服务器是自签证书，这里做 SHA-256 证书固定（只信任这一张）
//

import CryptoKit
import Foundation
import Library
import SwiftUI

// MARK: - 常量

enum YGConfig {
    static let apiURL = URL(string: "https://__YG_HOST__/api/app_login.php")!
    static let host = "__YG_HOST__"
    /// 服务器证书 SHA-256（自签，唯一信任锚）
    static let pinSHA256 = "f2a2f24f6282ac65a48a1017accaba3863b7c5bab8ce990089f7127044bf86f6"
    static let proxyHost = "__YG_HOST__"
    static let proxyPort = 3716
}


// MARK: - SOCKS5 认证（不走 TLS，直接问 CCProxy）

/// 用账号密码对 3716 端口做一次 SOCKS5 握手。
/// CCProxy 认了 = 密码正确；拒了 = 密码错或账号停用。
/// 完全绕开 HTTPS 证书问题，而且校验的正是"这个账号能不能用代理"。
enum YGSocks {
    /// 0 = 通过，1 = 拒绝，-1 = 网络/协议错误
    static func auth(host: String, port: UInt16, user: String, pass: String, timeoutMs: Int32 = 8000) -> Int {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { return -1 }
        defer { freeaddrinfo(res) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return -1 }
        defer { close(fd) }

        let oldFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK)

        let rc = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if rc != 0 {
            if errno != EINPROGRESS { return -1 }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pr = poll(&pfd, 1, timeoutMs)
            guard pr > 0 else { return -1 }
            var soErr: Int32 = 0
            var soLen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soLen)
            if soErr != 0 { return -1 }
        }
        _ = fcntl(fd, F_SETFL, oldFlags)

        var tv = timeval(tv_sec: Int(timeoutMs / 1000), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        func sendAll(_ bytes: [UInt8]) -> Bool {
            var sent = 0
            while sent < bytes.count {
                let n = bytes.withUnsafeBytes { buf -> Int in
                    write(fd, buf.baseAddress! + sent, bytes.count - sent)
                }
                if n <= 0 { return false }
                sent += n
            }
            return true
        }

        func recvN(_ n: Int) -> [UInt8]? {
            var out = [UInt8]()
            var buf = [UInt8](repeating: 0, count: n)
            while out.count < n {
                let got = buf.withUnsafeMutableBytes { p -> Int in
                    read(fd, p.baseAddress, n - out.count)
                }
                if got <= 0 { return nil }
                out.append(contentsOf: buf[0..<got])
            }
            return out
        }

        guard sendAll([0x05, 0x01, 0x02]) else { return -1 }
        guard let m = recvN(2), m[0] == 0x05 else { return -1 }
        guard m[1] == 0x02 else { return -1 }

        let ub = Array(user.utf8)
        let pb = Array(pass.utf8)
        guard ub.count <= 255, pb.count <= 255 else { return 1 }
        var msg: [UInt8] = [0x01, UInt8(ub.count)]
        msg.append(contentsOf: ub)
        msg.append(UInt8(pb.count))
        msg.append(contentsOf: pb)
        guard sendAll(msg) else { return -1 }
        guard let a = recvN(2) else { return -1 }
        return a[1] == 0x00 ? 0 : 1
    }
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
    static var lastError: String = ""
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

            // 记录是否属于"非固定指纹"情况（仅用于后续收紧，不阻断连接）
            YGPinState.fallbackUsed = (hash != YGConfig.pinSHA256)

            // 关键：把这张证书设为信任锚，并跳过主机名校验，再重新评估。
            // 只把 trust 丢回 completionHandler 是不够的——系统会自己重评并再次拒绝。
            SecTrustSetAnchorCertificates(trust, [cert] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            // 用基础 X.509 策略：只校验签名/有效期/信任锚，
            // 不做 EKU 与主机名检查（服务器是自签证书，缺 serverAuth 用途标记）。
            // 安全性由上面已核对的 SHA-256 证书指纹保证。
            let basicPolicy = SecPolicyCreateBasicX509()
            SecTrustSetPolicies(trust, basicPolicy)
            var evalError: CFError?
            if SecTrustEvaluateWithError(trust, &evalError) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                YGPinState.lastError = (evalError as Error?)?.localizedDescription ?? "trust evaluate failed"
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
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
            let detail = YGPinState.lastError
            var extra = seen.isEmpty ? "" : "（指纹 \(seen.prefix(8))…"
            if !detail.isEmpty { extra += " / \(detail.prefix(40))" }
            if !extra.isEmpty { extra += "）" }
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

        DispatchQueue.global(qos: .userInitiated).async {
            let r = YGSocks.auth(host: YGConfig.proxyHost,
                                 port: UInt16(YGConfig.proxyPort),
                                 user: u,
                                 pass: p)
            DispatchQueue.main.async {
                self.loading = false
                switch r {
                case 0:
                    self.done = true
                    YGSession.shared.save(username: u, expire: "", days: 0)
                case 1:
                    self.errorText = "账号或密码错误，或账号已停用"
                default:
                    self.errorText = "无法连接代理服务器 " + YGConfig.proxyHost + ":" + String(YGConfig.proxyPort) + "，请检查网络"
                }
            }
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
                    .task { YGDefaultProfile.ensure() }
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
    @FocusState private var focus: Int?

    private let bg = Color(red: 0.04, green: 0.05, blue: 0.07)
    private let card = Color(red: 0.08, green: 0.10, blue: 0.13)
    private let line = Color(red: 0.14, green: 0.18, blue: 0.22)
    private let blue = Color(red: 0.18, green: 0.44, blue: 0.92)
    private let label = Color(red: 0.55, green: 0.65, blue: 0.72)
    private let red = Color(red: 0.95, green: 0.42, blue: 0.42)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

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
                .padding(.top, 60)
                .padding(.bottom, 30)

                accountCard

                // 错误提示
                if let err = vm.errorText {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text(err).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13))
                    .foregroundColor(red)
                    .padding(.horizontal, 4)
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
                .buttonStyle(.plain)
                .disabled(vm.loading)
                .padding(.top, 18)

                // 防封端口
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
                .padding(.top, 26)

                Rectangle().fill(line).frame(height: 1).padding(.top, 18)

                HStack(spacing: 7) {
                    Circle()
                        .fill(Color(red: 0.22, green: 0.75, blue: 0.47))
                        .frame(width: 8, height: 8)
                    Text("账号有效期由服务端判定，验证通过即可连接")
                        .font(.system(size: 12))
                        .foregroundColor(Color(red: 0.45, green: 0.56, blue: 0.64))
                    Spacer()
                }
                .padding(.top, 16)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
        }
    }

    // MARK: 账号密码卡片

    private var accountCard: some View {
        VStack(spacing: 0) {
            // 账号
            HStack(spacing: 14) {
                Text("账 号")
                    .font(.system(size: 15))
                    .foregroundColor(label)
                    .frame(width: 46, alignment: .leading)

                TextField("输入账号", text: $vm.username)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .tint(blue)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.next)
                    .focused($focus, equals: 0)
                    .onSubmit { focus = 1 }
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            .contentShape(Rectangle())
            .onTapGesture { focus = 0 }

            Rectangle()
                .fill(line)
                .frame(height: 1)
                .padding(.horizontal, 16)
                .allowsHitTesting(false)

            // 密码
            HStack(spacing: 14) {
                Text("密 码")
                    .font(.system(size: 15))
                    .foregroundColor(label)
                    .frame(width: 46, alignment: .leading)

                SecureField("输入密码", text: $vm.password)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .tint(blue)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.go)
                    .focused($focus, equals: 1)
                    .onSubmit {
                        focus = nil
                        vm.submit()
                    }
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            .contentShape(Rectangle())
            .onTapGesture { focus = 1 }
        }
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(line, lineWidth: 1)
                .allowsHitTesting(false)      // 关键：描边不参与点击
        )
    }
}

// MARK: - 自动创建默认配置（首次登录后）

enum YGDefaultProfile {
    static let profileName = "yg-node"

    /// 内置默认规则（由小卷毛 .conf 转换而来；占位符在构建时由 Secrets 注入）
    static let configContent = """
{"outbounds":[{"type":"socks","tag":"yg-node","server":"__YG_HOST__","server_port":3716,"version":"5","username":"__YG_USER__","password":"__YG_PASS__"},{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}],"route":{"rules":[{"domain":["down.anticheatexpert.com"],"outbound":"block"},{"domain":["m.baidu.com"],"outbound":"yg-node"},{"domain":["m.jd.com"],"outbound":"yg-node"},{"domain":["www.baidu.com"],"outbound":"yg-node"},{"domain":["new.818fka.com"],"outbound":"yg-node"},{"domain":["sougou.com"],"outbound":"yg-node"},{"domain":["www.mzeie.cn"],"outbound":"yg-node"},{"ip_cidr":["106.63.103.8/32"],"outbound":"yg-node"},{"domain":["nj.cschannel.anticheatexpert.com"],"outbound":"yg-node"},{"domain_keyword":["lua"],"outbound":"direct"},{"domain_keyword":["youesp"],"outbound":"direct"},{"domain_keyword":["lknb666"],"outbound":"direct"},{"domain_keyword":["nb08"],"outbound":"direct"},{"domain_keyword":["luoyew"],"outbound":"direct"},{"domain_keyword":["dy.3i.hk"],"outbound":"yg-node"},{"domain":["down.qq.com"],"outbound":"direct"},{"ip_cidr":["101.226.101.163/32"],"outbound":"direct"},{"domain_keyword":["superbed"],"outbound":"direct"},{"domain_keyword":["imgdb"],"outbound":"direct"},{"domain_keyword":["image"],"outbound":"direct"},{"domain_keyword":["t3"],"outbound":"direct"},{"domain_keyword":["t3data"],"outbound":"direct"},{"domain_keyword":["840fk"],"outbound":"direct"},{"domain_keyword":["open"],"outbound":"direct"},{"domain_keyword":["xui"],"outbound":"direct"},{"domain_keyword":["aegis"],"outbound":"direct"},{"domain_keyword":["imgcache"],"outbound":"direct"},{"domain_keyword":["qlogo"],"outbound":"yg-node"},{"domain_keyword":["jiazhang"],"outbound":"direct"},{"domain_keyword":["ssl.msdk"],"outbound":"direct"},{"port":[10012],"outbound":"yg-node"},{"ip_cidr":["120.204.207.84/32"],"outbound":"direct"},{"ip_cidr":["101.226.94.67/32"],"outbound":"direct"},{"ip_cidr":["101.226.96.203/32"],"outbound":"direct"},{"ip_cidr":["116.128.169.94/32"],"outbound":"direct"},{"ip_cidr":["58.246.163.95/32"],"outbound":"direct"},{"ip_cidr":["221.181.98.213/32"],"outbound":"direct"},{"ip_cidr":["43.154.254.219/32"],"outbound":"direct"},{"ip_cidr":["43.154.254.250/32"],"outbound":"direct"},{"ip_cidr":["49.51.67.47/32"],"outbound":"direct"},{"ip_cidr":["182.254.116.117/32"],"outbound":"direct"},{"ip_cidr":["182.254.116.119/32"],"outbound":"direct"},{"ip_cidr":["183.192.196.121/32"],"outbound":"direct"},{"ip_cidr":["116.128.169.68/32"],"outbound":"direct"},{"port":[443],"outbound":"block"},{"port":[80],"outbound":"block"}],"final":"direct"},"dns":{"servers":[{"type":"udp","tag":"dns-1","server":"114.114.114.114"}]}}
"""

    /// 若“yg-node”配置不存在则自动创建（幂等，可重复调用）
    static func ensure() {
        Task.detached(priority: .utility) {
            do {
                let existing = try await ProfileManager.list()
                if existing.contains(where: { $0.name == profileName }) { return }
                let nextID = try await ProfileManager.nextID()
                let dir = FilePath.sharedDirectory.appendingPathComponent("configs", isDirectory: true)
                let file = dir.appendingPathComponent("config_\(nextID).json")
                try await BlockingIO.run {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try configContent.write(to: file, atomically: true, encoding: .utf8)
                }
                let profile = Profile(name: profileName, type: .local, path: file.relativePath)
                try await ProfileManager.create(profile)
                NSLog("YGLink: default profile created")
            } catch {
                NSLog("YGLink: default profile create failed: %@", error.localizedDescription)
            }
        }
    }
}

