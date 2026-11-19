# Kaka

Kaka 是一个 iPhone 说唱交流应用框架。四个入口依次是直播间、语音房、AI 词谱和我的。现阶段打开应用就能浏览房间、查看并关注示例主持人、用节拍器排练和编辑词谱。关注、收藏、排练笔记、个人资料和保存的词谱留在设备上。

## 工程入口

- iOS 工程和 Scheme 均为 Kaka。React Native 入口为 src/App.tsx，业务页面在 web/app。
- Xcode 的资源阶段包含 ios/Kaka/Kaka.zip 及其校验索引。修改网页或占位图后，执行 npm run package:web 更新这两份资源。此命令只归档已有文件。
- 准备构建时，在仓库根目录执行 npm ci 和 bundle install，再到 ios 目录执行 bundle exec pod install。用 Xcode 27.1 或更新支持同一 SDK API 的版本打开 ios/Kaka.xcworkspace，选择 Kaka。物理设备构建需要自己的开发签名。
- Debug 和 Release 配置均从 App 安装包读取 React Native 的 JS bundle。Xcode 构建阶段生成该 bundle，业务页面从同包 ZIP 加载。

## 当前边界

AI 词谱以离线规则生成初稿，支持题目、风格、BPM、小节数与押韵配置。直播间和语音房当前展示示例阵容，排练席和节拍器可离线使用。真实账户、直播流、多人连麦、线上推理和内购属于后续接入阶段。

- [产品范围](docs/DEVELOPMENT_REQUIREMENTS.md)
- [技术版本](docs/TECH_STACK.md)
- [本地数据与桥接](docs/WEB_BRIDGE_CONTRACT.md)
- [视觉与 Duo](docs/UI_DESIGN_FUSION.md)
- [素材](docs/MEDIA_INVENTORY.md) · [资源大小](docs/SIZE_BUDGET.md)

已通过 Xcode 27.1 的 Debug iOS 模拟器（arm64）编译。应用运行、浏览器交互与真机验收仍待验证。
