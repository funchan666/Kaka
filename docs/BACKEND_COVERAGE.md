# Kaka 后端能力核对

本表按参考包里的调用处、请求字段、响应解析和第三方 SDK 记录协议。接口名称保留原约定，参考工程的代码、资源、审核数据和语言包不进入 Kaka。状态以源码为依据，服务联通、权限、计费和真机结果须分别验证。

SAPI 单独处理票据交换、语音房和房内操作。RTC、RTM 与 NIM 分别承载媒体、通话信令和消息。以下状态按当前客户端源码记录，实测范围仍以设备和服务联调结果为准。

## 业务覆盖

| 能力 | 参考实现与协议 | Kaka 状态与依赖 |
| --- | --- | --- |
| 启动和鉴权 | `/console/unseal` 接收 `consoleDialect` 和 `orbitZone`，返回 `liveConsolePlan`。邮箱 `/cipher/signal/launch`，Apple `/cipher/orbit/launch`，续期 `/cipher/pass/renew`，退出 `/cipher/exit`。 | 原生邮箱表单调用已有 Swift 鉴权层。创建账号与登录共用邮箱端点，是否新建由服务端决定。Keychain 保存服务会话。Apple 登录需要另行接入对应的 entitlement 和原生授权流程。 |
| 找回密码和删除账号 | `Presentation/Flows/Identity/AccountRecovery.swift` 的验证码、密码重置、删除预览和删除确认直接返回 `unavailableOperation`。 | 缺少服务端契约。退出或清理本地工作区不能代替远程删除。需要提供挑战和提交接口、锁定策略、删除鉴权及返回状态。 |
| 自己及他人资料 | `/r2/voyager/brief`，`/r2/voyager/refresh`，`/r2/voyager/identity-slate`，`/beacon/portrait`。头像上传先请求 `/r2/voyager/storage-vector`，由短期凭证限制对象存储范围。 | 已连接个人资料、艺名与简介、已知主持人资料。头像通过系统选择、压缩去元数据、签名上传和远端资料更新。 |
| 关注和用户发现 | `/r2/voyager/constellation`，`/r2/voyager/track/traveler`，`/nebula/scan/suggestions`，`/nebula/scan/query`，`/horizon/host/present`，`/horizon/nexus/grade`。关注与取消分别使用 `supportMode=1/2`。搜索发送 `stageRule`、`signalKind`、`folioIndex`、`folioScale`。 | 主持人档案和个人页承接关注及关注列表。直播和语音目录提供服务端推荐、按昵称或数字 ID 搜索与分页。直播的 New 分类读取主持人目录里的 `NEW` 等级，支持地区和分页。两种主持人结果均剔除当前账号和 NIM 屏蔽对象，点击打开资料。房间名称和话题在已加载房间中匹配。随机匹配及独立用户发现页暂无入口。 |
| 直播频道和播放 | `/horizon/sector`、`/nebula/broadcast/reels`、`/nebula/stream/reservoir`、`/nebula/studio/retrieve`、`/nebula/relay/passcode`、`/nebula/relay/identity-pass`、`/nebula/duel/brief`、`/nebula/duel/ladder`、`/v2/scan/stream/assembly`。`/broadcast/studio/condition` 用 `venueKey` 查直播状态。`/nebula/launch/flare` 用 `hostIdentity` 触发已装备的进场效果。 | 地区由服务端下发，按地区 ID 和页码查询直播。已接入播放、续签、滑动换房、观众、观看 PK 分屏和对战双方贡献榜。PK 仅加入经过房间详情确认的对手频道。带完整身份的直播间在首帧和聊天就绪后请求一次进场效果，处理可信 `ITEM_EFFECT(80)`。直播状态明确结束后关闭当前流，有下一场时可继续观看。观看选项支持高清和省流，省流取决于直播端是否提供低码流。参考包缺少主播开播、主动发起 PK 或观众上屏契约。 |
| 语音房和麦位 | SAPI 房间目录、`room/language/list`、`room/getMyRoomAndFamilyInfo`、建房资格、房间模板、背景及麦位。麦位使用 `seat/list`、`seat/getQueueSeatList`、`seat/exchangeSeat`、`seat/agreeSeat`、`seat/refuseQueueSeat`、`seat/lockSeat`、`seat/holdSeat` 和 `seat/switchRoomTemp` 等。 | 使用服务端语言目录过滤返回的房间，并显示从当前账号核实的「我的房间」，可一键回房。参考只返回一批房间，未提供分页游标。已接入创建、进退房、入麦、换位、排队、静音和麦克风。房主和管理员可更新公告、背景、房锁和麦位申请开关，处理申请、锁麦位、将成员移下麦或在账号满足等级要求时更换纯语音布局。提交前重新核对权限和房间。语音房只发布和接收音频。 |
| 语音房管理 | `room/getViewers`、`room/getRoomInfoCard`、`room/setAdmin`、`room/kickOutRoom`、`room/getKickOutBlacklist`、`room/removeKickOutBlacklist`、`room/getRecommendInviteList` 和 `room/inviteUserRoom`。麦位、排队、上麦审批和房间背景由 NIM 房间事件提示更新。 | 已接入成员列表、管理员分配、移出和暂时禁止进入、黑名单解除。已入房的成员可邀请推荐名单上的用户。收到可信且属于当前房间的事件后，刷新麦位、排队和背景或更新审批状态，麦位保留轮询。收到当前账号的移出通知后退出房间。 |
| 语音房音乐和表情 | SAPI `music/list`、`music/settings`、`music/enableMusic`、`music/play`、`music/like`、`music/uploadLocalMusic` 及 `room/getPartyRoomEmojis`。表情通过房内 NIM 自定义消息发布。 | 歌单支持点赞、开启播放和签名上传音频。只有获授权且开麦的在麦成员可通过 Agora 混音，离麦、闭麦或退房时停止。表情只显示在核对了发送账号和麦位的成员卡片上。 |
| 活动和榜单 | `/beacon/bulletin/gallery`、`/comet/satchel/inventory`、`/horizon/nexus/grade`、`/nebula/broadcast/standing` 与 SAPI 语音榜单。 | 首页和语音目录显示活动和榜单。钱包、只读礼物背包及帮助中心使用原生页面，同域 HTTPS 活动页在应用内打开，外链 HTTPS 地址交给系统打开。商城和邀请码在参考源码中是空分支。抽奖及游戏横幅的 H5 路由映射未包含在参考包中。 |
| 即时消息和推送 | NIM 处理私聊、会话列表、未读数和黑名单，`/beacon/portrait` 提供会话账号的资料。`/signal/public/forum-key` 提供公共频道材料。参考应用通过标准 APNs 获取 token，网关使用 `X-Signal-Pulse`，NIM 使用配置的推送证书名称。 | Profile 的 Messages 支持分页查看服务端私聊、未读数和历史，打开后清除相应未读。主播私聊支持系统选图、预览、确认发送和历史照片读取。音频空闲时支持录制最多 60 秒、预听、确认发送和点按播放普通语音消息，附件通过同一私聊会话校验。推送 token 仅用于当前验证会话。通知可前往通话记录、直播、资料、已校验的私聊，或按 ID 直达语音房。锁房可输入密码重试。未标明收件人的通知只用于收到点击时的会话。真实 APNs 和 NIM 投递待联调，付费私密媒体未接入。 |
| 实时通话 | `/voyager/relay/pass`、`/voyager/forge`、`/voyager/dock`、`/voyager/voice/ratio`、`/voyager/ignition`、`/voyager/debit`、`/voyager/transit/await`、`/voyager/transit/ticks`、`/voyager/closure`、`/voyager/lapse`、`/voyager/archive`。 | 已接入直播间拨出、前台来电接听和拒接、报价、权限及来电身份校验。通话内使用 NIM 临时文字。主动拨出的付费通话支持充值并在到账、余额及扣费确认后恢复。账号设置可查服务端通话记录。后台实时响铃仍需服务端 VoIP token 绑定、来电推送及 CallKit 联动，参考包只提供标准通知。 |
| 发布和动态 | `/r2/epochs/stream`、`/r2/epochs/endorse`、`/r2/epochs/retrieve-notes`、`/stardust/moment/reply`、`/r3/orbit/forge`。私有付费媒体 `/signal/private/verify` 和 `/signal/private/unseal`。 | 这些接口面向社交动态和私有媒体，与 Kaka 逐小节词谱及私人房间笔记语义不同。词谱或笔记跨设备同步需要相应存取契约。 |
| 举报和屏蔽 | `/nebula/echo/archive` 需要有效 `castEmblem`、原因 `reviewMode`，按需提交 `habitatTag`、`astralAdvice`、`fanAddress`、`stardustFrames`。参考屏蔽依赖 `/r2/voyager/track/traveler` 和 NIM 黑名单。 | 房间举报需要真实房间和用户关联。完整屏蔽及取消屏蔽需要 NIM。参考包没有可调用的普通反馈接口，客服与举报有各自的提交对象。 |
| 钱包、充值、补单 | `/r2/voyager/brief` 的 `starGems` 是余额。充值依次使用 `/r2/treasury/fuel-catalog`、`/r2/treasury/forge-ticket`、StoreKit、`/r2/treasury/confirm/lunar-acquire`、`/r2/treasury/ticket-phase`。 | Kaka 原生 StoreKit 读取实际价格、保存订单归属、核验回执和查询到账。余额只读真实账户值。商户需在 Kaka 的 App Store Connect 应用配置对应的产品，后端也须验证 Kaka bundle 的回执。 |
| 礼物 | 直播礼物使用 `/comet/offering/fourth-array`、`/nebula/cheer/transmit`，语音礼物使用 `gift/getPartyRoomGift`、`gift/sendGift`。私聊和视频通话使用 `/comet/offering/third-array`、`/horizon/comms/tribute` 和 `/voyager/tribute`。礼物墙和心愿单来自 `/r2/voyager/identity-slate` 和 `/nebula/fan/requests`。 | 普通及 PK 直播、语音房、私聊和直播间拨出的视频通话可送礼。接听后仅在 `/voyager/dock` 核实为普通视频或直播私聊视频并匹配对端时可送礼。动画支持 GIF、APNG、普通 MP4/MOV、基础 VAP、VAPX 同源静态图片，以及 SVGA 2.x 和旧版 SVGA ZIP 的包内位图、遮罩与常用矢量及裁剪路径，包括椭圆弧。动态资料替换与旋转遮罩保留 VAP 底片。SVGA 音轨与外部素材未接入，真实礼物样本播放待验证。私聊及视频送礼仅在服务端确认扣款后播放。 |
| VIP、签到、等级 | VIP 是账户字段 `cosmicPrivilege`、`starElite` 或有效 `stardustExpiry`，没有找到单独购买或激活接口。签到 `/beacon/arrival/brief` 和 `/beacon/arrival/execute`，等级 `/r2/voyager/rank-brief`。 | Wallet & rewards 包含签到和等级查询。服务端的资格与返回结果决定能否领取。参考的商城、背包、邀请入口是空分支，不构成业务契约。 |
| AI 写词 | `Runtime/Remote/GroqAssistantService.swift` 从包内私有配置读 bearer key，直接调用 Groq，示例能力为简介、回复建议、翻译。服务端网关没有写词接口。 | 已接好 `verse.generate` 的英语请求、词谱校验和错误状态。仍需部署带认证及额度控制的同网关代理，返回 Kaka 词谱结构。 |
| 设置与客服 | FAQ `/r2/voyager/liaison/anomalies`，在线客服 `/r2/voyager/liaison/console` 后进入 NIM 会话。通知分类、缓存维护、语言选择在参考工程本地。 | Profile 和活动入口的 Help center 均可查看 FAQ、复制内容或打开服务端确认的页面，以及向服务端指定的客服账号发送文字。账号设置可打开系统通知权限和通话记录。协议链接应对应 Kaka 的实际运营主体和数据处理。 |

## 配置与依赖

- 主网关和 SAPI 使用不同运行时票据及 AES 包装。服务路径和字段的编码是协议兼容项。仅从通过认证的启动响应获取 RTC、SAPI 和 socket 参数。
- 客户端只持有实际运行所需的 app 标识、可公开连接参数及受会话绑定的短期票据。AI 提供方 key、对象存储服务端密钥和支付验证密钥由服务器负责。私有生产值不写进仓库或日志。
- StoreKit 原生回调关联账户、服务租户、SKU、订单和 Apple transaction ID。退到后台或退出登录时回执待处理记录仍保留，归属正确的账户恢复后继续结算。
- SDK 的现有安装记录不能证明服务 entitlement 生效。RTC、IM、RTM、推送、对象存储和 App Store Connect 分别需要有效的应用配置。
- APNs 需要 Kaka App ID 的 Push Notifications capability、匹配环境的签名配置和推送服务。NIM 投递使用与 Kaka bundle 匹配的 `KAKA_NIM_APNS_CERTIFICATE` 构建设置，客户端源码不包含证书密钥。

## 本次功能范围

直播和语音房按参考包中可接入的流程实现。观众侧保留直播播放和 PK 分屏、比分、倒计时及贡献榜，支持隐藏和恢复直播控件。主持人档案通过 `/beacon/portrait` 与 `/beacon/relay/quantum-scan-id` 读取在播直播和所在语音房，入房前再核对当前房间。

语音房收到可信的 `1016` 房间改锁事件后，核实普通成员的当前入房和角色，再通过现有密码流程重新进房。活动轮播只展示有已接入目标的卡片。全部活动行都被过滤时，目录展示房间推荐。

主播开播和停播、直播公开连麦、主播主动 PK、后台系统来电、无目标的商城与邀请活动，以及缺少完整扣费和入口协议的转盘和游戏，均排除在本次实现范围内。参考包中的付费私密媒体有查询和解锁接口，本次范围限于已有的普通私聊媒体。语音房目录沿用参考的一批房间请求。

## 联调验收

1. 英文界面下验证全新邮箱、既有邮箱、无效密码、令牌续期、登出和切换账户。验证第二个账户读不到第一个账户的本地工作和原生会话。提供真实的账号删除并验证服务端删除。
2. 使用有权限的测试房间验证目录、进入、视频接收、语音接收、麦克风授权与回收、Room/RTC 离开和重连。双设备验证成员状态、实时消息、通话、屏蔽和举报结果。
3. 使用 Kaka 的沙盒商品验证取消、待批准、退款或失败、重复回调、离线重试和恢复。只有订单确认到账才结束购买交易，并与钱包查询核对。Gift、签到和付费媒体验证重复提交不重复扣款或发放。
4. 用授权的写词代理验证登录要求、速率限制、结构化词谱、无网失败和用户取消。对远程发布、附件和私信分别验证访问权限、媒体校验及错误反馈。
