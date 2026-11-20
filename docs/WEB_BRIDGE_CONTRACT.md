# 原生服务桥接

KakaArchive 从应用资源读取 ZIP 和 SHA-256 索引，核对路径、文件数量和大小、膨胀比、CRC 与逐文件摘要。归档版本 4 对应线上账号契约。重新打包业务页面不覆盖 Application Support 下的用户记录。

WKWebView 只为当前本地索引开放读权限。原生桥要求调用来自当前 WebView、主框和当前索引。页面脚本及 CSS 来自应用资源，远程媒体图片仅允许 HTTPS。网关、Socket、Agora、NIM、照片上传和 StoreKit 由原生层处理。第三方政策阅读使用独立 WebView。[WebKit 本地加载](https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl(_:allowingreadaccessto:)) · [WebKit 消息回调](https://developer.apple.com/documentation/webkit/wkscriptmessagehandlerwithreply)

## 消息

每条消息有 `version=1`、UUID 格式的 `id` 和 `command`。结果回送同一 `id`。失败回送受控英文错误码。

| 命令 | 输入和用途 |
| --- | --- |
| `ready` | 返回可用尺寸、各边安全区、遮挡区域、辅助功能和玻璃能力。先于业务请求调用。 |
| `welcome.glass` 和 `dock.glass` | 以 Web 容器坐标声明原生按钮位置。底栏同时带当前 tab。 |
| `media.frame` | 在当前直播详情内声明可见视频区域。区域随屏幕、视口、滚动及遮挡实时验证，null 隐藏。 |
| `auth.session` | 读已验证远端会话，必要时启动并验证令牌。返回用于桥接的 UUID、邮箱和艺名，或 null。 |
| `auth.register` 和 `auth.login` | 邮箱、密码和显式协议同意。注册另有艺名。两条入口使用同一已公开的生产认证端点。 |
| `auth.signOut` 和 `auth.delete` | 当前会话 UUID。登出撤销本地会话并请求服务端退出。远端账号删除需要未提供的生产契约。 |
| `records.read` 和 `records.write` | 当前会话 UUID，写入另含 revision 与 recordJSON；返回原子提交的版本。词谱草稿、书签、笔记和本地隐藏按远端账号隔离。 |
| `service.request` | `session`、命名的 `operation` 及 `input`。原生层控制契约、字段、身份、所属房间和工作区；网页不持有网络地址或服务令牌。 |

## 业务请求

- 目录、档案、关注和举报经固定网关或 SAPI 路由。个人头像使用系统选择器和短期上传凭证。
- 直播和语音媒体在实际 SDK 回调后更新。语音麦位经 SAPI 和 WSS 会话维持，权限、发布状态及退出由原生控制。房间和私聊传递经 NIM 确认的消息。
- 商店从 StoreKit 返回当前商店价格，服务端钱包确认订单实际到账后才结束交易。网页仅传选定的产品标识。
- `verse.generate` 需要在同一网关部署可认证的 `versePath`。输入含题目、风格、BPM、小节数、押韵和可选房间 ID。返回 `{bars:[{section,text,rhyme,cue}]}`，长度必须与请求一致。模型凭据只在服务端使用。

几何变化只重排原页面和原生媒体位置。导航、会话更换、后台和 Web 内容重载会按各自所有权关闭已退出的频道及聊天。应用支持降低动态效果和降低透明度。
