# Kaka 后端能力核对

本表按参考包里的调用处、请求字段、响应解析和第三方 SDK 记录协议。接口名称保留原约定，参考工程的代码、资源、审核数据和语言包不进入 Kaka。状态以源码为依据，服务联通、权限、计费和真机结果须分别验证。

SAPI 单独处理票据交换、语音房和房内操作。RTC、RTM 与 NIM 分别承载媒体、通话信令和消息。以下状态按当前客户端源码记录，实测范围仍以设备和服务联调结果为准。

## 业务覆盖

| 能力 | 参考实现与协议 | Kaka 状态与依赖 |
| --- | --- | --- |
| 启动和鉴权 | `/console/unseal` 接收 `consoleDialect` 和 `orbitZone`，返回 `liveConsolePlan`。邮箱 `/cipher/signal/launch`，Apple `/cipher/orbit/launch`，续期 `/cipher/pass/renew`，退出 `/cipher/exit`。 | 原生邮箱表单调用已有 Swift 鉴权层。创建账号与登录共用邮箱端点，是否新建由服务端决定。Keychain 保存服务会话。Apple 登录需要另行接入对应的 entitlement 和原生授权流程。 |
| 找回密码和删除账号 | `Presentation/Flows/Identity/AccountRecovery.swift` 的验证码、密码重置、删除预览和删除确认直接返回 `unavailableOperation`。 | 缺少服务端契约。退出或清理本地工作区不能代替远程删除。需要提供挑战和提交接口、锁定策略、删除鉴权及返回状态。 |
| 自己及他人资料 | `/r2/voyager/brief`，`/r2/voyager/refresh`，`/r2/voyager/identity-slate`，`/beacon/portrait`。头像上传先请求 `/r2/voyager/storage-vector`，由短期凭证限制对象存储范围。 | 已连接个人资料、艺名与简介、已知主持人资料。头像通过系统选择、压缩去元数据、签名上传和远端资料更新。 |
| 关注和用户发现 | `/r2/voyager/constellation`，`/r2/voyager/track/traveler`，`/horizon/sector`，`/horizon/nexus/grade`，`/horizon/host/present`。关注与取消分别使用 `supportMode=1/2`。 | 现有主持人档案和个人页承接关注及关注列表。搜索、分页、排行榜、随机匹配和独立用户发现页仍需对应入口。 |
| 直播频道和播放 | `/nebula/broadcast/reels`、`/nebula/studio/retrieve`、`/nebula/relay/passcode`、`/nebula/relay/identity-pass`、`/nebula/duel/brief`、`/nebula/duel/ladder`、`/v2/scan/stream/assembly`。 | 已接入播放、续签、滑动换房、真实观众、观看 PK 分屏和对战双方贡献榜。PK 仅加入经过房间详情确认的对手频道。参考包没有开放主播发起 PK 或观众上屏流程。 |
| 语音房和麦位 | SAPI 房间目录、建房资格、语种、房间模板、背景及麦位。麦位使用 `seat/list`、`seat/getQueueSeatList`、`seat/exchangeSeat`、`seat/giveUpQueueSeat`、`seat/agreeSeat` 和 `seat/refuseQueueSeat` 等。 | 已接入创建、进退房、入麦、换位、取消排队、静音和麦克风。房主和管理员通过房间设置更新公告、背景、锁房和麦位申请开关，或处理待审批的麦位申请。每次提交前重新校验权限和当前房间。参考源码中的语音房只订阅和发布音频。 |
| 活动和榜单 | `/beacon/bulletin/gallery`、`/horizon/nexus/grade`、`/nebula/broadcast/standing` 与 SAPI 语音榜单。 | 首页和语音目录显示实际活动数据。已接入全局、房间榜单，已知钱包和帮助链接使用原生页面。其他活动路径需要明确的目标和配置。 |
| 即时消息和推送 | `Runtime/Communication/Messenger.swift` 使用 NIM 做私聊、会话、未读、历史、发图和黑名单。`RoomChat.swift` 加入聊天室，网关 `/signal/public/forum-key` 提供公共频道材料。系统通知和客服账号来自启动及 `/r2/voyager/liaison/console`。 | 已连接房间文字消息、主持人文字私聊、实际历史和黑名单。私聊发送前核对双向资格。会话总表、附件、推送和客服会话尚待接入。 |
| 实时通话 | `/voyager/relay/pass`、`/voyager/forge`、`/voyager/dock`、`/voyager/voice/ratio`、`/voyager/ignition`、`/voyager/debit`、`/voyager/transit/await`、`/voyager/transit/ticks`、`/voyager/closure`、`/voyager/lapse`。 | 已接入直播间发起、前台来电接听和拒接、报价、权限与来电账号校验。通话内的文字使用 NIM 临时消息，离开时清空。主动拨出的付费通话支持充值等待。收到认证的到账通知并重新核对余额与扣费回执后，回到通话画面继续同一通话。扣费结果不明时结束通话。 |
| 发布和动态 | `/r2/epochs/stream`、`/r2/epochs/endorse`、`/r2/epochs/retrieve-notes`、`/stardust/moment/reply`、`/r3/orbit/forge`。私有付费媒体 `/signal/private/verify` 和 `/signal/private/unseal`。 | 这些接口面向社交动态和私有媒体，与 Kaka 逐小节词谱及私人房间笔记语义不同。词谱或笔记跨设备同步需要相应存取契约。 |
| 举报和屏蔽 | `/nebula/echo/archive` 需要有效 `castEmblem`、原因 `reviewMode`，按需提交 `habitatTag`、`astralAdvice`、`fanAddress`、`stardustFrames`。参考屏蔽依赖 `/r2/voyager/track/traveler` 和 NIM 黑名单。 | 房间举报需要真实房间和用户关联。完整屏蔽及取消屏蔽需要 NIM。参考包没有可调用的普通反馈接口，客服与举报有各自的提交对象。 |
| 钱包、充值、补单 | `/r2/voyager/brief` 的 `starGems` 是余额。充值依次使用 `/r2/treasury/fuel-catalog`、`/r2/treasury/forge-ticket`、StoreKit、`/r2/treasury/confirm/lunar-acquire`、`/r2/treasury/ticket-phase`。 | Kaka 原生 StoreKit 读取实际价格、保存订单归属、核验回执和查询到账。余额只读真实账户值。商户需在 Kaka 的 App Store Connect 应用配置对应的产品，后端也须验证 Kaka bundle 的回执。 |
| 礼物 | 直播礼物使用 `/comet/offering/fourth-array`、`/nebula/cheer/transmit`，语音礼物使用 `gift/getPartyRoomGift`、`gift/sendGift`。礼物墙来自 `/r2/voyager/identity-slate`，心愿单来自 `/nebula/fan/requests`。 | 已接入普通直播和 PK 直播向当前主播送礼、语音房按在麦成员多选、数量确认、收送礼物墙和心愿单。发送前复核会话、收礼对象、报价和余额。跨房广播动效、私聊和通话送礼仍待接入。 |
| VIP、签到、等级 | VIP 是账户字段 `cosmicPrivilege`、`starElite` 或有效 `stardustExpiry`，没有找到单独购买或激活接口。签到 `/beacon/arrival/brief` 和 `/beacon/arrival/execute`，等级 `/r2/voyager/rank-brief`。 | Wallet & rewards 包含签到和等级查询。服务端的资格与返回结果决定能否领取。参考的商城、背包、邀请入口是空分支，不构成业务契约。 |
| AI 写词 | `Runtime/Remote/GroqAssistantService.swift` 从包内私有配置读 bearer key，直接调用 Groq，示例能力为简介、回复建议、翻译。服务端网关没有写词接口。 | 已接好 `verse.generate` 的英语请求、词谱校验和错误状态。仍需部署带认证及额度控制的同网关代理，返回 Kaka 词谱结构。 |
| 设置与客服 | FAQ `/r2/voyager/liaison/anomalies`，在线客服 `/r2/voyager/liaison/console` 后进入 NIM 会话。通知分类、缓存维护、语言选择在参考工程本地。 | Profile 的 Help center 已连接 FAQ。客服会话和通知设置待接入。协议链接当前按参考配置设置，正式配置应对应 Kaka 的实际运营主体和数据处理。 |

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
