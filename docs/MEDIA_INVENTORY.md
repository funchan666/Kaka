# 原生应用素材

iOS 主屏幕图标使用用户提供的原图。账号入口照片中的人物为虚构场景。项目的生成提示与素材来源记录保存在 [image-prompts.json](../assets/brand/image-prompts.json) 和 [original-asset-plan.json](../assets/brand/original-asset-plan.json)。

## 随包图片

SwiftUI 从 [images](../ios/Kaka/images) 读取下列图片。Xcode 将目录以 `images` 的名称复制进应用。

| 图片 | 尺寸 | 用途 |
| --- | --- | --- |
| `entry-cypher-portrait.jpg` | 899 × 1750 | 欢迎页的说唱人物照，构图保留脸部和麦克风 |
| `entry-reunion.jpg` | 1448 × 1086 | 登录页的卡座合照 |
| `entry-writing-table.jpg` | 1448 × 1086 | 注册页的一起写词场景 |
| `live-deck.jpg` | 1320 × 880 | 小场地演出照，作为直播精选和常规房间的备用封面 |
| `voice-deck.jpg` | 1320 × 880 | 冷蓝录音台，供快速练习与语音房空状态使用 |
| `stage.jpg` | 960 × 1440 | 直播场景的备用舞台图 |
| `voice.jpg` | 1000 × 1500 | 语音房的备用排练台图 |
| `notebook.jpg` | 1000 × 1500 | 写词灵感卡的备用图 |
| `member-mark.jpg` | 384 × 384 | 资料页和房间内的备用头像 |
| `room-watch.png`、`room-listen.png`、`room-write.png` | 各 128 × 128 | 观看、监听、排练和写词入口 |
| `action-bookmark.png`、`action-check.png`、`action-close.png`、`action-delete.png`、`action-edit.png`、`action-forward.png`、`action-play.png`、`action-seat.png`、`action-stop.png` | 各 96 × 96 | 收藏、确认、关闭、删除、编辑、进入、播放、入座和停止 |

## Asset Catalog

| 资源 | 尺寸 | 用途 |
| --- | --- | --- |
| `AppIcon` | 40 至 1024 像素 | iOS 主屏幕图标 |
| `KakaBrand` | 480 × 480 | 系统 Launch 与 SwiftUI 启动层 |
| `StartupRhythm` | 192 × 72 | 系统 Launch、应用启动与登录等待的原创玻璃节拍键 |
| `Dock-stage`、`Dock-voice`、`Dock-notebook`、`Dock-crate` | 各 84 × 84 | 直播、语音房、写词和个人页的底栏图标 |
| `WorkspaceStudioLight` | 1440 × 960 | 四个主页面顶部的紫粉录音室光影 |
| `LiveEmptyStage` | 1440 × 600 | 直播列表空状态与首屏加载失败 |
| `VerseSignalStudio` | 1440 × 720 | 写词页开场和生成状态的原创玻璃声波雕塑 |
| `ProfileSignalCover` | 1440 × 720 | 个人页的原创烟紫玻璃唱片封面 |

其余生成原图保存在项目的素材源目录。房间封面和头像优先使用服务端提供的数据。直播媒体由 Agora 传输，语音房节拍声由应用生成。
