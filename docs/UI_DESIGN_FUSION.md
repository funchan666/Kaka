# 界面方向与适配

欢迎页使用唱片咖啡馆的竖版合照铺满屏幕。围桌聊天的几位朋友是主角，短标题和注册入口位于画面下方，登录位于右上。登录页的照片是老朋友在卡座交谈，注册页的照片是朋友一起写词。两张表单贴在照片下方，字段采用细线边界，协议区放在提交按钮下方。Live 做房间发现，Voice 提供排练席，Write 是逐小节的英文词谱编辑器，Profile 集中关注、作品、收藏及账号管理。

照片保留暖灯和傍晚窗光，遮罩集中在状态栏与文字区。表单接缝有雾紫磨砂和高光。iOS 26 及以上在空间足够且支持透明度时用 UIKit Liquid Glass 显示欢迎页注册按钮。普通网页按钮可随表单滚动和缩放。开启降低透明度时使用实色底。房间与排练界面使用墨蓝底、冷蓝台灯和玫红边光。[Apple 材质指南](https://developer.apple.com/design/human-interface-guidelines/materials)

使用马甲包的 RN 和本地 WebView 架构、UI Design Reference、UI Taste、Impeccable 文本流程、Claude Design 和 Garden Web Design Engineer。三张账号入口照片使用 Garden Image 2 的宿主模式制作。账号页用 Avenir Next 组织层级，英文正文和交互使用系统无衬线字体。iOS 主屏幕图标使用正方形画布，交由系统裁切外形。[Apple App Icon 指南](https://developer.apple.com/design/human-interface-guidelines/app-icons)

## Duo 静态实现

- 原生视图沿用所属 Scene，随容器更新 WebView frame、各侧安全区和 27.1 的活动预留区域。图片可延伸，按钮和标题按触及的区域避让。
- 欢迎图可延伸到安全区之外，标题与操作留在可用区域内。窄屏账号页上下排，宽容器把表单放到照片右侧。键盘出现时压缩表单上方间距。协议页使用同一 Scene 的独立阅读面板，关闭后恢复原表单和勾选状态。[Apple iPhone Duo 布局指南](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- 可见 viewport 缩小并且正在输入时收起浮动底栏。正常浏览按底栏实测高度为滚动内容预留空间。
- 键盘显示、旋转和开合只更新样式。Tab、房间选择、各页滚动位置与正在编辑的词谱由当前页面会话保留。切离语音页或 Scene 失活会停止节拍。
- 已核对代码、实际 SDK 声明、原始素材和压缩图。当前版本的页面渲染、交互、编译及设备姿态待实测。
