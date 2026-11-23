# 静态资源大小

以下为 Kaka 原生 target 中各资源的源文件字节数。

| 资源 | 文件数 | 字节 |
| --- | ---: | ---: |
| `ios/Kaka/images` 照片 | 9 | 2,371,618 |
| `ios/Kaka/images` 透明 PNG | 12 | 102,252 |
| `Images.xcassets` 图像 | 18 | 1,837,900 |
| `Images.xcassets` 清单 | 12 | 3,379 |
| `LaunchScreen.storyboard` 与 `PrivacyInfo.xcprivacy` | 2 | 7,913 |
| 合计 | 53 | 4,323,062 |

本地图片中最大的三张是注册页的 `entry-writing-table.jpg`（461,961 字节）、欢迎页的 `entry-cypher-portrait.jpg`（445,277 字节）和登录页的 `entry-reunion.jpg`（409,522 字节）。三张合计 1,316,760 字节，保留了原图像素尺寸。

直播媒体走 Agora 实时通道。上表仅统计静态资源源文件。原生代码、第三方 SDK、私有配置、签名、App Thinning、.app 和 IPA 的大小以实际产物为准。包体目标为 50,000,000 字节。
