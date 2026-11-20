# Kaka 后端能力核对

本表按参考包里的调用处、请求字段、响应解析和第三方 SDK 记录协议。接口名称保留原约定，参考工程的代码、资源、审核数据和语言包不进入 Kaka。状态以源码为依据，服务联通、权限、计费和真机结果须分别验证。

## 业务覆盖

| 能力 | 参考实现与协议 | Kaka 状态与依赖 |
| --- | --- | --- |
| 启动和鉴权 | `/console/unseal` 接收 `consoleDialect` 和 `orbitZone`，返回 `liveConsolePlan`。邮箱 `/cipher/signal/launch`，Apple `/cipher/orbit/launch`，续期 `/cipher/pass/renew`，退出 `/cipher/exit`。 | 邮箱使用参考网关的真实流程。创建账号与登录共用邮箱端点，是否新建由服务端决定。Keychain 保存服务会话，网页持有会话引用。Apple 登录需要另行接入对应的 entitlement 和原生授权流程。 |
| 找回密码和删除账号 | `Presentation/Flows/Identity/AccountRecovery.swift` 的验证码、密码重置、删除预览和删除确认直接返回 `unavailableOperation`。 | 缺少服务端契约。退出或清理本地工作区不能代替远程删除。需要提供挑战和提交接口、锁定策略、删除鉴权及返回状态。 |
| 自己及他人资料 | `/r2/voyager/brief`，`/r2/voyager/refresh`，`/r2/voyager/identity-slate`，`/beacon/portrait`。头像上传先请求 `/r2/voyager/storage-vector`，由短期凭证限制对象存储范围。 | 接入计划按现有艺名和简介入口读写真实资料。媒体上传还需要对象存储签名、图片检查、替换和引用确认。 |
| 关注和用户发现 | `/r2/voyager/constellation`，`/r2/voyager/track/traveler`，`/horizon/sector`，`/horizon/nexus/grade`，`/horizon/host/present`。关注与取消分别使用 `supportMode=1/2`。 | 现有主持人档案和个人页承接关注及关注列表。搜索、分页、排行榜、随机匹配和独立用户发现页仍需对应入口。 |
| 直播频道和播放 | `/nebula/broadcast/reels`，`/nebula/studio/retrieve`，`/nebula/relay/passcode`，`/nebula/relay/identity-pass`，`/broadcast/studio/condition`。参考用 Agora 播放和重连。 | 直播列表与详情应只用服务返回。真实播放依赖该安装所属运行时 RTC App ID、房间 channel、token 和 UID。PK、申请上屏、观众、直播榜单及主持角色另有契约。 |
| 语音房和麦位 | SAPI `room/list`、`room/enter`、`room/exitRoom`、`seat/list`、`seat/getQueueSeatList`。Agora 负责媒体，NIM room chat 负责成员及麦位事件。 | 列表和真实 RTC 进房与房间管理是不同范围。上麦需要服务端授权、对应角色、权限以及麦位心跳，不能由本地节拍器或前端座位状态充当。房主创建、封面、公告、密码、背景、邀请、禁言、踢出、音乐、队列及榜单仍需各自的房间权限。 |
| 即时消息和推送 | `Runtime/Communication/Messenger.swift` 使用 NIM 做私聊、会话、未读、历史、发图和黑名单。`RoomChat.swift` 加入聊天室，网关 `/signal/public/forum-key` 是公共频道材料的一部分。系统通知和客服账号来自启动及 `/r2/voyager/liaison/console`。 | REST 数据读取无法替代即时聊天。需要 Kaka 对应的 NIM SDK、账号票据、会话映射、消息流和 APNs 配置。跨账户、重连、幂等收发、后台推送均待联调。 |
| 实时通话 | `Runtime/Communication/CallCoordinator.swift` 用 Agora RTM 信令和 RTC 媒体，涉及 `/voyager/relay/pass`、`/voyager/forge`、`/voyager/dock`、`/voyager/ignition`、`/voyager/debit`、`/voyager/transit/await`、`/voyager/transit/ticks`、`/voyager/closure`、`/voyager/lapse`、`/voyager/archive`。 | 单纯加入 RTC 房间不能替代通话邀请、接听、挂断及计费。需要 RTM SDK、来电授权与付费账本联调。 |
| 发布和动态 | `/r2/epochs/stream`、`/r2/epochs/endorse`、`/r2/epochs/retrieve-notes`、`/stardust/moment/reply`、`/r3/orbit/forge`。私有付费媒体 `/signal/private/verify` 和 `/signal/private/unseal`。 | 这些接口面向社交动态和私有媒体，与 Kaka 逐小节词谱及私人房间笔记语义不同。词谱或笔记跨设备同步需要相应存取契约。 |
| 举报和屏蔽 | `/nebula/echo/archive` 需要有效 `castEmblem`、原因 `reviewMode`，按需提交 `habitatTag`、`astralAdvice`、`fanAddress`、`stardustFrames`。参考屏蔽依赖 `/r2/voyager/track/traveler` 和 NIM 黑名单。 | 房间举报需要真实房间和用户关联。完整屏蔽及取消屏蔽需要 NIM。参考包没有可调用的普通反馈接口，客服与举报有各自的提交对象。 |
| 钱包、充值、补单 | `/r2/voyager/brief` 的 `starGems` 是余额。充值依次使用 `/r2/treasury/fuel-catalog`、`/r2/treasury/forge-ticket`、StoreKit、`/r2/treasury/confirm/lunar-acquire`、`/r2/treasury/ticket-phase`。 | Kaka 原生 StoreKit 读取实际价格、保存订单归属、核验回执和查询到账。余额只读真实账户值。商户需在 Kaka 的 App Store Connect 应用配置对应的产品，后端也须验证 Kaka bundle 的回执。 |
| 礼物 | 网关 `/comet/offering/third-array`、`/comet/offering/fourth-array` 和 SAPI `gift/getPartyRoomGift` 读取各场景礼物。私聊 `/horizon/comms/tribute`，通话 `/voyager/tribute`，直播 `/nebula/cheer/transmit`，语音房 `gift/sendGift`。 | 赠送需要由当前已授权会话绑定真实房间、目标和付费渠道。公开房间礼物动效依赖 NIM 广播。流程须串行扣费、处理重复响应并刷新余额。要同时满足这些条件后才能提供赠送入口。 |
| VIP、签到、等级 | VIP 是账户字段 `cosmicPrivilege`、`starElite` 或有效 `stardustExpiry`，没有找到单独购买或激活接口。签到 `/beacon/arrival/brief` 和 `/beacon/arrival/execute`，等级 `/r2/voyager/rank-brief`。 | Wallet & rewards 包含签到和等级查询。服务端的资格与返回结果决定能否领取。参考的商城、背包、邀请入口是空分支，不构成业务契约。 |
| AI 写词 | `Runtime/Remote/GroqAssistantService.swift` 从包内私有配置读 bearer key，直接调用 Groq，示例能力为简介、回复建议、翻译。服务端网关没有写词接口。 | 写词需要带认证、额度限制和日志治理的服务端代理，返回 Kaka 词谱结构。本地模板或把生产供应商 key 打进包都不能作为交付。 |
| 设置与客服 | FAQ `/r2/voyager/liaison/anomalies`，在线客服 `/r2/voyager/liaison/console` 后进入 NIM 会话。通知分类、缓存维护、语言选择在参考工程本地。 | 可单独启用真实 FAQ 与客服联系人。当前产品统一英语，合法本地偏好及缓存不属于审核 Mock。协议链接应对应 Kaka 实际运营主体和数据处理。 |

## 配置与依赖

- 主网关和 SAPI 使用不同运行时票据及 AES 包装。服务路径和字段的编码是协议兼容项。仅从通过认证的启动响应获取 RTC、SAPI 和 socket 参数。
- 客户端只持有实际运行所需的 app 标识、可公开连接参数及受会话绑定的短期票据。AI 提供方 key、对象存储服务端密钥和支付验证密钥由服务器负责。私有生产值不写进仓库或日志。
- StoreKit 原生回调关联账户、服务租户、SKU、订单和 Apple transaction ID。退到后台或退出登录时回执待处理记录仍保留，归属正确的账户恢复后继续结算。
- SDK 的现有安装记录不能证明服务 entitlement 生效。RTC、IM、RTM、推送、对象存储和 App Store Connect 分别需要有效的应用配置。

## 联调验收

1. 英文界面下验证全新邮箱、既有邮箱、无效密码、令牌续期、登出和切换账户。验证第二个账户读不到第一个账户的本地工作和原生会话。提供真实的账号删除并验证服务端删除。
2. 使用有权限的测试房间验证目录、进入、视频接收、语音接收、麦克风授权与回收、Room/RTC 离开和重连。双设备验证成员状态、实时消息、通话、屏蔽和举报结果。
3. 使用 Kaka 的沙盒商品验证取消、待批准、退款或失败、重复回调、离线重试和恢复。只有订单确认到账才结束购买交易，并与钱包查询核对。Gift、签到和付费媒体验证重复提交不重复扣款或发放。
4. 用授权的写词代理验证登录要求、速率限制、结构化词谱、无网失败和用户取消。对远程发布、附件和私信分别验证访问权限、媒体校验及错误反馈。
