# Web 容器和记录

KakaArchive 从 App 自带的资源读取 ZIP 和 SHA-256 索引。首次安装或归档变更时，检查 ZIP、文件白名单、大小、膨胀比、CRC 和逐文件 SHA-256，再写入当前有效版本。写入失败时可回退到已经验证的版本。内容区位于 Application Support/Kaka/Content，记录区位于 Application Support/Kaka/State。重新打包网页不会替换用户记录。

KakaOfflineView 以 WKWebView 加载已确认的 index.html。读权限限于该版资源目录。请求来源须为当前 WebView 的主框、同一个本地 index.html。二级路由用片段切换，CSP 禁止网络连接、子框架和表单导航。原生方法使用 WKScriptMessageHandlerWithReply 返回结果。 [WKWebView 本地加载](https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl(_:allowingreadaccessto:)) · [WebKit 消息回调](https://developer.apple.com/documentation/webkit/wkscriptmessagehandlerwithreply)

## 命令

每条消息包含 version=1、UUID 格式的 id 和 command。成功响应回送同一个 id 及 value。

| 命令 | 额外输入 | 返回 |
| --- | --- | --- |
| ready | 无 | 当前容器宽高、边距、活动预留区与降低透明度设置 |
| records.read | 无 | revision 与 recordJSON。空记录使用 revision 0。 |
| records.write | 当前 revision 与 recordJSON | 已原子提交的下一版快照。页面握手前拒绝写入。 |

recordJSON 限长 512 KiB，v1 包含 profile、favorites、following、notes、scores、reports。v1 缺少 following 时按空列表读入。写入带版本检查，拒绝过期快照。网页串行提交，超时读回已保存快照以处理提交成功但响应丢失。资料、关注、藏品、笔记和草稿从同一份快照刷新。一次保存的词谱最多 16 小节，草稿箱最多 40 份。

几何变化通过 kaka:geometry 更新页面布局。离开语音房、页面隐藏或 Scene 失活触发节拍停止。排练席和带入的编辑词谱保留于当前页面会话；需要跨重启保留的词谱由使用者保存。Web 内容进程中断时提供重新加载，已保存记录从原生区恢复。

线上接入点是 core/catalog.js 的场次与主持读取、VerseNotebook/lyrics.js 的 generate 请求和返回，以及后续的房间实时状态。当前使用随包目录和离线写词提供方。
