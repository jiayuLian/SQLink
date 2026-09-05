# SQLink · iOS 远程 MySQL 客户端（TrollStore 版）

一个**纯 Swift** 写的 iOS MySQL 客户端，参考 Navicat 的交互：管理连接、浏览库/表/字段、查看数据、执行 SQL。
无需 Apple 开发者账号，通过 GitHub Actions 出 IPA，用**巨魔 TrollStore** 一键安装。

## 特性
- 多连接管理，连接信息（密码）存入 iOS **Keychain**，安全可靠
- 库 / 表（含视图）/ 字段结构浏览，数据前 100 行预览
- SQL 查询控制台，结果以清晰的表格展示（NULL / 类型一目了然）
- **TLS 加密连接**支持（可信任自签名证书，方便自签 MySQL）
- `mysql_native_password` 与 `caching_sha2_password` 两种认证均支持
- 清爽的 SwiftUI 界面，支持搜索、横竖屏

## 最低要求
- iOS 15.0+（巨魔 TrollStore 2 支持的系统）
- 不需要 Apple 开发者账号，由巨魔负责安装/签名

---

## 方式一：GitHub Actions 直接出 IPA（无需 Mac）
1. 把这个 `SQLink` 目录推到你的 GitHub 仓库（已包含 `.github/workflows/build.yml`）。
2. 仓库 → **Actions** → 选择 `Build IPA (TrollStore)` → **Run workflow**。
3. 跑完后在 **Artifacts** 下载 `SQLink-ipa`（即 `SQLink.ipa`）。
4. 把 IPA 传到 iPhone（AirDrop / 文件 App），用**巨魔 TrollStore** 打开安装即可。

## 方式二：Mac + Xcode 自己编
1. 安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
2. 在仓库根目录执行 `xcodegen generate` 生成 `SQLink.xcodeproj`。
3. 双击用 Xcode 打开，选 `Any iOS Device (arm64)`，`Product → Build`
   （工程已设 `CODE_SIGNING_ALLOWED=NO`，无需签名）。
4. 找到产物 `SQLink.app`，手动打包：
   ```bash
   mkdir -p Payload
   cp -R SQLink.app Payload/
   zip -r SQLink.ipa Payload
   ```
5. AirDrop 传到 iPhone，巨魔打开安装。

---

## 安全说明
- 数据库**密码只存在本机 Keychain**，不会离开设备，也不会写进仓库。
- 远程连接建议开启 **TLS**（MySQL 需配置 SSL）；自签证书可在连接里勾选「信任自签名证书」。
- 若 MySQL 暴露在公网，强烈建议配合**防火墙/白名单**或 SSH 隧道使用，不要长期裸奔。
- 本 App 仅供个人管理与学习使用，请遵守相关服务条款与法律法规。

## 目录结构
```
SQLink/
├── project.yml              # XcodeGen 工程定义（无签名 IPA）
├── make_icon.py             # 生成 App 图标（纯标准库，无依赖）
├── .github/workflows/build.yml
└── SQLink/
    ├── SQLinkApp.swift
    ├── Models.swift
    ├── KeychainHelper.swift
    ├── ConnectionStore.swift
    ├── MySQLWire.swift       # 协议底层：哈希 / 长度编码 / 解析
    ├── MySQLConnection.swift  # 连接、握手、认证、查询解析
    ├── ConnectionsView.swift
    ├── ConnectionEditorView.swift
    ├── DatabaseBrowserView.swift
    ├── QueryConsoleView.swift
    ├── Components.swift
    ├── Info.plist
    └── Assets.xcassets/
```
