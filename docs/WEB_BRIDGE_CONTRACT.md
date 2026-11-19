# Web 容器和记录

KakaArchive 从 App 自带的资源读取 ZIP 和 SHA-256 索引。首次安装或归档变更时，检查 ZIP、文件白名单、大小、膨胀比、CRC 和逐文件 SHA-256，再写入当前有效版本。写入失败时可回退到已经验证的版本。内容区位于 Application Support/Kaka/Content，记录区位于 Application Support/Kaka/State。重新打包网页不会替换用户记录。

KakaOfflineView 以 WKWebView 加载已确认的 index.html。读权限限于该版资源目录。请求来源须为当前 WebView 的主框、同一个本地 index.html。二级路由用片段切换，CSP 禁止网络连接、子框架和表单导航。原生方法使用 WKScriptMessageHandlerWithReply 返回结果。 [WKWebView 本地加载](https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl(_:allowingreadaccessto:)) · [WebKit 消息回调](https://developer.apple.com/documentation/webkit/wkscriptmessagehandlerwithreply)

## 命令

每条消息包含 version=1、UUID 格式的 id 和 command。成功响应回送同一个 id 及 value。

| 命令 | 额外输入 | 返回 |
| --- | --- | --- |
| ready | 无 | 当前容器宽高、边距、活动预留区、降低透明度设置和 welcomeGlass 支持状态 |
| welcome.glass | 可见区域坐标 frame 含 x、y、width、height、viewportWidth、viewportHeight。null 隐藏按钮。 | 布局是否支持原生玻璃按钮 |
| auth.session | 无 | 当前会话的临时 token、邮箱和初始艺名，或 null |
| auth.register | name、email、password、acceptedPolicies=true | 已持久化的邮箱账号会话 |
| auth.login | email、password、acceptedPolicies=true | 已重新验证凭据的邮箱账号会话 |
| auth.signOut / auth.delete | 当前会话 token（session） | 操作后的会话状态 |
| records.read | 当前会话 token（session） | revision 与 recordJSON。空记录使用 revision 0。 |
| records.write | 当前会话 token（session）、revision 与 recordJSON | 已原子提交的下一版快照 |

账号操作、记录读写由同一个原生 actor 串行处理。修改命令须先完成 ready。账号保存在仅本机解锁时可读的 Keychain 中。密码以随机盐和 PBKDF2-HMAC-SHA256 校验值持久化，桥接的响应不返回密码、盐或校验值。每次登录生成新的会话 token，读写要求 token 对应有效邮箱账号。新账号用独立的 UUID 文件名。删号先撤销会话和账号，再清理该账号的记录文件。文件清理失败时下次打开重试。

升级时退出旧访客会话。设备尚无邮箱账号且有可读取的旧访客记录时，注册会把作品复制到首个本机账号，并以新注册的艺名作为资料名。原记录继续存在沙盒内。归档索引版本为 3，缓存回退要求匹配新版协议流程。邮箱账号、会话和作品沿用原存储。

登录和注册的协议选项默认未勾选。网页在提交前校验，原生桥接也要求本次提交显式确认。登录、注册与 Profile 共享 `policies/terms.html` 和 `policies/privacy.html`。由当前主 WebView 受信任页面的点击请求打开独立阅读面板。协议面板的 WKWebView 没有业务桥接。正式链接分别填入 `ios/Kaka/Info.plist` 的 `KakaTermsURL` 和 `KakaPrivacyURL`，接受 HTTPS 地址。两项留空时打开各自的英文占位页。[WebKit 导航代理](https://developer.apple.com/documentation/webkit/wknavigationdelegate)

recordJSON 限长 512 KiB，v1 包含 profile、favorites、following、notes、scores、reports。v1 缺少 following 时按空列表读入。写入带版本检查，拒绝过期快照。网页串行提交，超时读回已保存快照以处理提交成功但响应丢失。资料、关注、藏品、笔记和草稿从同一份快照刷新。一次保存的词谱最多 16 小节，草稿箱最多 40 份。

几何变化通过 kaka:geometry 更新页面布局。离开语音房、页面隐藏或 Scene 失活触发节拍停止。排练席和带入的编辑词谱保留于当前页面会话；需要跨重启保留的词谱由使用者保存。Web 内容进程中断时提供重新加载，已保存记录从原生区恢复。

欢迎页只在注册入口完整可见且无需滚动或缩放时发送坐标。原生校验容器宽高、安全区和活动预留区，确认后显示 UIKit 玻璃按钮。点击调用同一个网页注册链接。几何变化时重新定位，打开其他页面时隐藏该按钮。[UIKit UIGlassEffect](https://developer.apple.com/documentation/uikit/uiglasseffect)

线上接入点是 core/catalog.js 的场次与主持读取、VerseNotebook/lyrics.js 的 generate 请求和返回，以及后续的房间实时状态。当前使用随包目录和离线写词提供方。
