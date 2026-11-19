# Kaka

Kaka 是一个全英文 iPhone 说唱交流应用框架。通过欢迎页注册或登录本机邮箱账号后，可进入 Live、Voice、Write 和 Profile。用户可以浏览房间、关注示例主持人、用节拍器排练和编辑词谱。关注、收藏、笔记和草稿按账号保存在设备上。

## 工程入口

- iOS 工程和 Scheme 均为 Kaka。React Native 入口为 src/App.tsx，业务页面在 web/app。
- Xcode 的资源阶段包含 ios/Kaka/Kaka.zip 及其校验索引。修改网页或占位图后，执行 npm run package:web 更新这两份资源。此命令只归档已有文件。
- 准备构建时，在仓库根目录执行 npm ci 和 bundle install，再到 ios 目录执行 bundle exec pod install。用 Xcode 27.1 或更新支持同一 SDK API 的版本打开 ios/Kaka.xcworkspace，选择 Kaka。物理设备构建需要自己的开发签名。
- Debug 和 Release 配置均从 App 安装包读取 React Native 的 JS bundle。Xcode 构建阶段生成该 bundle，业务页面从同包 ZIP 加载。

## 当前边界

Verse Lab 以离线规则生成英文初稿，支持题目、风格、BPM、小节数与押韵配置。邮箱账号仅用于本机注册和登录。直播间和语音房使用示例阵容，排练和节拍器可离线使用。直播流、多人连麦、跨设备账号、线上推理和内购待接入。

- [产品范围](docs/DEVELOPMENT_REQUIREMENTS.md)
- [技术版本](docs/TECH_STACK.md)
- [本地数据与桥接](docs/WEB_BRIDGE_CONTRACT.md)
- [视觉与 Duo](docs/UI_DESIGN_FUSION.md)
- [素材](docs/MEDIA_INVENTORY.md) · [资源大小](docs/SIZE_BUDGET.md)

更早的版本已通过 Xcode 27.1 的 Debug 模拟器编译和启动。当前入口及图标改版完成源码、工程配置和 ZIP 静态核对，编译、运行和实际交互待验证。
