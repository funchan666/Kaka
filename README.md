# Kaka

Kaka 是全英文 iPhone 说唱交流应用。客户端使用真实邮箱账号、直播与语音房目录、原生实时通道及 StoreKit。设备保留当前已验证账号的房间书签、私人笔记和词谱草稿。

## 工程入口

- 用 Xcode 27.1 或兼容版本打开 `ios/Kaka.xcworkspace`，选择 Kaka Scheme。物理设备构建使用项目现有的开发签名配置。
- `SceneDelegate.swift` 用 UIKit 建立窗口，SwiftUI 实现账号、直播、语音、词谱和个人页。iOS 26 及以上的底栏和主操作使用系统 Liquid Glass。
- 首次配置依赖时，在仓库根目录运行 `bundle install`，然后执行 `bundle exec pod install --project-directory=ios`。CocoaPods 负责 Agora 和 NIM 依赖。
- Xcode 资源阶段直接收录原创图片、App Icon 和 LaunchScreen。`web/app/assets/images` 是图片资源目录。旧网页源码、ZIP 和旧宿主文件保留作迁移参考，均在当前 iOS target 之外。

## 服务配置

本机配置放在被 Git 忽略的 `ios/Kaka/KakaService.private.json`。写入 `origin`、`appId` 和网关要求的 `aesKey`、`aesIv` 后，Xcode 将它加入原生资源。可选字段有 `termsURL`、`privacyURL`、语音心跳用的 `socketAesKey`、以及部署在同一网关的词谱 `versePath`。应用身份继续使用 Kaka 的 Bundle ID。部署时确认所有配置和协议属于实际运营环境，供应商私有模型密钥只放服务端。

- [历史接入计划](docs/superpowers/plans/2026-11-20-live-services.md)
- [后端覆盖和联调验收](docs/BACKEND_COVERAGE.md)

- [产品范围](docs/DEVELOPMENT_REQUIREMENTS.md)
- [技术版本](docs/TECH_STACK.md)
- [视觉与 Duo](docs/UI_DESIGN_FUSION.md)
- [素材](docs/MEDIA_INVENTORY.md) · [资源大小](docs/SIZE_BUDGET.md)

真实服务的源码、依赖和资源与 iOS 编译、设备媒体、账号权限及沙盒结算属于不同验收项。
