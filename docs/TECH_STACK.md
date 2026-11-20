# 工具链

| 项目 | 配置 |
| --- | --- |
| iOS 启动 | Swift、UIKit、UIHostingController |
| 应用界面 | SwiftUI · iOS 26 起的原生 Liquid Glass · 早期系统使用 Ultra Thin Material |
| 工程与 Scheme | `ios/Kaka.xcworkspace` · Kaka |
| 运行目标 | iPhone，iOS 15.1 起 |
| 开发工具 | Xcode 27.1 与 iOS 27.1 SDK |
| 原生依赖 | CocoaPods 1.16.2 · Agora RTC 4.5.0 · NIM 10.9.10 |
| 社交与购买 | Swift 鉴权及服务层、原生 RTC 和消息、StoreKit |
| 本地数据 | Keychain 会话、应用支持目录的账号隔离 JSON 草稿和房间记录 |

`SceneDelegate` 创建系统窗口和根视图。图片由 Asset Catalog 及独立图片资源目录提供。授权、麦克风和购买使用平台原生流程。SwiftUI 在支持时查询当前容器的预留区域，其他版本使用系统安全区。

已静态核对 Swift 源码、Xcode 资源引用和 Pods。应用构建、真机运行、账号服务和购买按各自的验收结果记录。
