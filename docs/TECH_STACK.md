# 工具链

| 项目 | 配置 |
| --- | --- |
| iOS 宿主 | React Native 0.88.1 · React 19.3.0 · TypeScript 6 · Hermes |
| App 名称与 Scheme | Kaka |
| 开发标识 | com.kakastudio.kaka，项目内初始值 |
| 运行目标 | iPhone，iOS 15.1 起 |
| 开发工具 | Xcode 27.1 与 iOS 27.1 SDK，支持原生预留区域 API |
| 依赖 | Node ^22.13 或 ^24.3 或 26 起 · npm 锁文件 · CocoaPods 1.16.2 · Xcodeproj 1.27.0 · ZIPFoundation 0.9.20 |
| Web 运行时 | HTML、CSS、JavaScript，通过 Fabric 挂载的 WKWebView 加载 App 内文件 |

iOS 工程取自官方社区模板的 0.88.1 iOS 部分。SceneDelegate 使用 RN 0.88 的单 Scene 启动接口。离线 WebView 专注经核验的页面路径、消息来源和本地读写。没有附加 Web 框架、JS 运行时 CDN 或本地 HTTP 服务。 [React Native 0.88 发布说明](https://reactnative.dev/blog/2026/10/19/react-native-0.88) · [Fabric 原生组件](https://reactnative.dev/docs/fabric-native-components-introduction) · [ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.20)

iOS 15.1 采用当前 RN 的最低部署设置。iOS 27.1 的 UIKit 预留区域查询有可用性判断，低版本使用容器尺寸和安全区。当前机器上的 Xcode SDK 头文件含相关声明。 [React Native iOS 最低版本源码](https://github.com/facebook/react-native/blob/v0.88.1/packages/react-native/scripts/cocoapods/helpers.rb) · [Apple iPhone Duo 适配](https://developer.apple.com/iphone-duo/prepare/) · [UIKit 预留区域](https://developer.apple.com/documentation/uikit/uiview/reservedregions(kind:options:))

npm 依赖和 Pods 已在本机安装，Ruby 与 Pods 版本分别记录在 Gemfile.lock 和 ios/Podfile.lock。已用 ios/Kaka.xcworkspace 完成 Debug iOS 模拟器（arm64）编译。设备签名、启动与性能仍待验证。
