# YG Link iOS —— 未签名 IPA 云编译

用 GitHub Actions 的 macOS 机器，把 **sing-box 官方 iOS 客户端**复制一份、换成你的品牌，产出**未签名 IPA**，你拿去第三方签名服务（企业签/超级签）重签后装到 iPhone。

不需要 Mac，不需要 Apple 开发者账号，只需要一个 GitHub 账号。

---

## 一、这套东西干什么

```
GitHub Actions (macOS)
  ├─ 克隆 sing-box             → 编 Libbox.xcframework（内核，Go）
  ├─ 克隆 sing-box-for-apple   → 官方 iOS 客户端源码
  ├─ 打品牌补丁                → 改名字、改图标、改 bundle id
  ├─ xcodebuild archive        → 不签名编译
  └─ 打包 Payload/*.app        → YGLink-unsigned.ipa
```

产物 `YGLink-unsigned.ipa` 拿去签名服务商那边重签 → 装到手机。

---

## 二、你需要做的（按顺序）

### 1. 建 GitHub 仓库
新建一个**私有仓库**（Private），名字随意，比如 `yg-link-ios`。

### 2. 把这个目录推上去
把本目录下的**所有文件**（包括 `.github` 这个隐藏目录）推到仓库根目录：

```
你的仓库/
├─ .github/workflows/ios-unsigned.yml
├─ scripts/rebrand.sh
├─ scripts/make_icon.py
├─ assets/icon-1024.png
├─ config/yg-node.json
└─ README.md
```

> `.github` 是隐藏目录，Windows 资源管理器默认能看到但推的时候别漏。

### 3. 触发编译
仓库页面 → **Actions** → 左侧 `Build unsigned IPA` → 右侧 **Run workflow**：

| 参数 | 填什么 |
|---|---|
| `app_id` | `com.yglink.app`（或你自己的反域名，别用别人的） |
| `app_name` | `YG Link`（手机桌面显示的名字） |
| `app_ref` | `dev`（默认，不用改） |

点绿色 **Run workflow**，等 **20–40 分钟**。

### 4. 下载产物
跑完后进这次运行 → 页面底部 **Artifacts** → 下载 `YGLink-unsigned-ipa`。
解压得到 `YGLink-unsigned.ipa`。

### 5. 拿去签名
把 IPA 交给你的签名服务商，**必须确认这两点**（否则装上去 VPN 起不来）：

- 证书带 **Network Extension**（`packet-tunnel-provider`）权限 —— VPN 类 App 专用，普通 App 签名证书可能没有
- 重签时 **App 和 PlugIns/Extension.appex 都要签**，且 **App Group** 保持一致

签完得到一个可安装的 IPA → 用签名商给的安装页/描述文件装到手机上。

---

## 三、装好之后怎么用

1. 打开 App（名字是你填的 `app_name`）
2. 第一次会要装 **VPN 配置**，点允许
3. 回来点 **连接**，状态变成已连接
4. 需要导入节点：把 [`config/yg-node.json`](config/yg-node.json) 的内容粘进去，或用「从文件导入」

节点配置里已经写好了：

```json
{ "type": "socks", "server": "192.140.176.22", "server_port": 3716,
  "username": "xjy2003", "password": "xjy2003" }
```

---

## 四、常见问题

**Q：编译失败了怎么办？**
Actions 页面会留下 `build-logs` 附件（`xcodebuild.log`），把最后 100 行发我。

大概率是这两个原因：
- **Xcode 版本不够**：上游用了新 SDK。改 `runs-on: macos-15` 为 `macos-26`（如果 GitHub 已经有这个镜像），或在「选择 Xcode」步骤里换版本。
- **SwiftPM 拉包超时**：重跑一次即可。

**Q：能改 App 名字/图标吗？**
能。`app_name` 参数改名字；`assets/icon-1024.png` 换图标（1024×1024，别带透明通道）。

**Q：为什么不能直接装？**
iOS 要求所有 App 必须有签名。未签名 IPA 只能自己签名或用签名服务，这是系统限制不是技术问题。

**Q：我以后想加节点/换节点怎么办？**
App 里可以直接编辑配置，不用重新编译。只有改名字/图标才需要重新跑 Actions。

---

## 五、这套方案的边界（说清楚）

- 它复用的是 **sing-box 官方客户端**，内核和隧道实现是上游维护的，稳定性和兼容性跟着上游走
- 我们只改了品牌和默认配置，没动协议栈
- 上游更新后，改 `app_ref` 或 `SB_REF` 就能升级内核版本
