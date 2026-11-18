# 0.2.1 修正版（build 4）

修正用户实际反馈：普通图片导入照片库的 3302、微博 Live 图片被当成静态图片、媒体下载未携带目标页面来源与浏览器标识。15 项原生测试通过，包含在临时模拟器照片库中实际导入 JPEG 与 WebP 测试图片。成功运行：https://github.com/dlwlrmazxr-hue/xhs-original-live/actions/runs/44331056206

普通图片按真实文件格式补齐扩展名；系统以 3302 拒绝原文件时，先保留原文件到 App 的「下载原文件」目录，再尝试原尺寸 PNG 相册副本。转换不会用于 Live 封面，动画／多帧图也不会被静默压成单张静态图。「文件」App 可访问保留的原文件。

微博 Live 优先读取详情 pic_ids/pic_infos 中的配对数据，同时支持移动页 pics 的 livephoto/videoSrc 字段；只有同时取得图片和对应动态文件才标记为可下载实况。仍需用户手机验证真实帖子的下载与保存。

抖音真实图集的网页动态视频已通过浏览器下载验证；本版调整了 App 的媒体请求来源与标识，并显示 HTTP 状态及资源主机，方便定位 App 与网页的差异。其非 JPEG、无现成实况标识的封面仍不支持 Live 合成，不能承诺该图集全部成功。

以下是 0.2 基础说明，微博 Live 支持范围以本节为准。

# 原图实况 0.2

在 iPhone 本机保存小红书图片、视频和原图封面的 Live Photo。0.2 新增抖音、微博、Instagram 帖子图片／视频解析，以及 App 内的官方网页登录／验证入口；加入原创桌面图标。

## 当前验证结果

- 0.1 已完成 Xcode 编译、5 项原生测试，并得到用户在 iOS 27.2 上安装与使用成功的反馈。
- 0.2 最终带图标安装包（0.2.0，build 3）已完成 10 项原生测试，0 失败，并成功编译 arm64 真机 IPA。成功运行：https://github.com/dlwlrmazxr-hue/xhs-original-live/actions/runs/44318518932 。原生测试使用合成样本，不包含用户笔记或媒体。
- 用户提供的抖音／Instagram 帖子在无登录探测中返回了网页，但未给出完整初始媒体数据；微博要求访客验证或拒绝匿名接口。三篇帖子的实际下载、网页登录和相册保存仍待真机验证，不能把单元测试通过当作真实下载成功。

使用与升级步骤见 [UPGRADE-0.2.md](UPGRADE-0.2.md)。

## 保存方式

复制具体帖子的分享链接或文案，选择图片／视频／实况类型，点击开始保存。平台要求登录或验证时，可打开「网页登录／验证」，在官方页面自行完成，再点「读取并保存」；移动分享页只显示打开 App 时，可尝试「标准网页」。

直接读取仅使用平台返回的资源，不使用公共解析服务器。可选登录状态留在本机 WebKit 数据区，不上传账号或 Cookie。只有匹配平台域名与路径的请求会附带本机 Cookie，跨主机重定向会剥离 Cookie。

平台未提供的原件清晰度无法恢复，已嵌入文件的水印不会被自动擦除。首版不支持直播、Story、主页批量下载、微博 TV 独立链接，也不绕过无权限内容的访问限制。资源地址可能过期，重新读取帖子后再试。

## 原图 Live Photo

- 封面来自高清图片资源，不从视频截帧。
- 已有有效 Apple MakerNote 17 标识的原图：整文件复制并逐字节校验，视频沿用同一标识。
- 无标识的普通 JPEG：仅补写配对元数据，保留压缩图像数据、尺寸和方向。不会假装保留所有被替换的 MakerNote 元数据。
- 无标识的 HEIC／PNG／MPO／HDR JPEG 暂不转换，避免重编码或破坏多图索引；已有标识且系统可识别的文件原样保留。
- 动态片段使用压缩采样直通，仅重新封装 MOV、添加标识和 still-image-time 轨道，保留可用音轨及方向。
- 先通过苹果 PHLivePhoto 识别检查，再保存为同一个照片资产。失败时显示真实错误及已保存数量。
- 实况片段上限 60 秒，单文件上限 512 MB。没有会员、广告或每日张数额度。

## Windows 编译与安装

公开仓库：https://github.com/dlwlrmazxr-hue/xhs-original-live

GitHub Actions 使用标准 macOS 编译机，公开仓库的标准编译免费。流程先运行全部原生测试，通过后生成未签名 IPA；安装包保留在 Actions 的 `XHSOriginalLive-unsigned-IPA` 中 7 天。

本地完整源码目录使用 `App/`、`Tests/`；公开仓库采用平铺 Swift 文件与对应 project.yml，两者均用 XcodeGen 生成同名项目。

在 Windows 从 [Sideloadly 官网](https://sideloadly.io/) 安装签名工具及其官方要求的 iTunes／iCloud 组件。用数据线连接并信任手机，拖入 IPA，使用自己的免费 Apple 账号安装。密码与验证码在自己的电脑／手机中完成，不需要提供给聊天。需要时按系统提示信任开发者、开启开发者模式。

使用与原版相同的 Apple 账号、目标手机和签名选项覆盖安装；不要先删除旧版。免费个人签名通常 7 天需要续签，与 App 的合成张数无关。

## 快捷指令

安装后新建快捷指令：添加「获取剪贴板」，再添加本 App 的「下载图片、视频或实况」，分享文案绑定剪贴板，下载类型设为「每次询问」。复制链接后运行，App 会处理保存；需要平台登录时，在 App 的官方网页入口完成。操作标识保留兼容，旧版小红书操作的显示名称在新版中更新。

## 参考与许可

- [Apple PHAssetCreationRequest](https://developer.apple.com/documentation/photos/phassetcreationrequest)
- [Apple WKHTTPCookieStore](https://developer.apple.com/documentation/webkit/wkhttpcookiestore)
- [Apple 个人开发账号](https://developer.apple.com/help/account/basics/about-your-developer-account/)
- [GitHub 编译机](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [yt-dlp 的平台结构参考](https://github.com/yt-dlp/yt-dlp/tree/master/yt_dlp/extractor)：本项目独立实现 Swift 解析器，不运行或打包 yt-dlp。

自编源码和原创图标按 MIT 许可提供，见 LICENSE。
