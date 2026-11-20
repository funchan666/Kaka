# Kaka

Kaka 是全英文 iPhone 说唱交流应用。客户端使用真实邮箱账号、直播与语音房目录、原生实时通道及 StoreKit。设备保留当前已验证账号的房间书签、私人笔记和词谱草稿。

## 工程入口

- iOS 工程和 Scheme 均为 Kaka。React Native 入口为 src/App.tsx，业务页面在 web/app。
- Xcode 的资源阶段包含 ios/Kaka/Kaka.zip 及其校验索引。修改网页后，执行 npm run package:web 更新这两份资源。此命令只归档已有文件。
- 准备构建时，在仓库根目录执行 npm ci 和 bundle install，再到 ios 目录执行 bundle exec pod install。用 Xcode 27.1 或更新支持同一 SDK API 的版本打开 ios/Kaka.xcworkspace，选择 Kaka。物理设备构建需要自己的开发签名。
- Debug 和 Release 配置均从 App 安装包读取 React Native 的 JS bundle。Xcode 构建阶段生成该 bundle，业务页面从同包 ZIP 加载。

## 服务配置

本机配置放在被 Git 忽略的 `ios/Kaka/KakaService.private.json`。写入 `origin`、`appId` 和网关要求的 `aesKey`、`aesIv` 后，Xcode 将它加入原生资源。可选字段有 `termsURL`、`privacyURL`、语音心跳用的 `socketAesKey`、以及部署在同一网关的词谱 `versePath`。应用身份继续使用 Kaka 的 Bundle ID。部署时确认所有配置和协议属于实际运营环境，供应商私有模型密钥只放服务端。

- [接入任务计划](docs/superpowers/plans/2026-11-20-live-services.md)
- [后端覆盖和联调验收](docs/BACKEND_COVERAGE.md)

- [产品范围](docs/DEVELOPMENT_REQUIREMENTS.md)
- [技术版本](docs/TECH_STACK.md)
- [业务桥接](docs/WEB_BRIDGE_CONTRACT.md)
- [视觉与 Duo](docs/UI_DESIGN_FUSION.md)
- [素材](docs/MEDIA_INVENTORY.md) · [资源大小](docs/SIZE_BUDGET.md)

真实服务的源码、依赖和资源与 iOS 编译、设备媒体、账号权限及沙盒结算属于不同验收项。
