# 实现路径

superuse 是 macOS 26+ 菜单栏应用。macOS 原生桌面 UI 使用 **AppKit**；UIKit 属于 iOS / Mac Catalyst。本项目不使用 SwiftUI，以 NSGlassEffectView、NSWindow、NSTableView、NSTextView 等原生组件实现。

## Tracer Bullets

1. 应用启动 → 菜单栏 → 全局快捷键 → 统一设置。先验证宿主和命令路由。
2. 系统剪贴板 → 本机持久化历史 → 分页快捷面板 → 按需读取 → 复制 / 回到来源应用粘贴 → 编辑。
3. 一个截图快捷键 → 定格屏幕 → 自动识别全屏 / 窗口或拖动选区 → 原位预览、标注与导出。
4. 在预览操作栏进入滚动 → 手动滚动采样 → 重叠检测 → 有界拼接 → 回到原位预览。
5. 构建、核心算法测试、原生 UI 验证和使用文档。

每条链路构建通过后提交。没有外部服务和第三方依赖。

最初四条功能链路已完成过 Release 打包、核心测试和 AppKit 集成测试；后续变更的实际验证见 `VERIFICATION.md` 中相应日期的记录。截图只暴露一个命令，保留原区域截图命令的 ID 以兼容已保存的快捷键。预览和标注复用同一覆盖层，不再另开编辑窗口。

## 边界

- `SuseCore`：可测试的数据模型、纯算法，与 AppKit 生命周期隔离。
- `App`：组合根、菜单栏、工具箱、统一设置窗口。
- `LoginItemSettingsView` 通过 `SMAppService.mainApp` 管理当前应用的登录项，以系统状态为准，不另存 UserDefaults 开关；注册失败恢复实际状态，等待批准时提供系统设置入口。`LoginItemService` 隔离系统调用，测试替身不会注册真实登录项。`AppLaunchContext` 识别系统登录启动事件，保留菜单栏功能并跳过工具箱自动展示。
- `mainApp` 首次查询可能因没有登录项记录而返回 `.notFound`。设置页仍允许用户打开开关，届时调用 `register()`；打开设置和刷新状态都不会自动注册。注册失败展示系统错误，并保留重试入口。
- `Shared`：功能接口、快捷键注册、设置存储和少量原生 UI 工具。
- `Features/Clipboard`、`Features/Screenshot`、`Features/Pins`、`Features/SystemMonitor`：各自持有状态、UI、服务，不相互调用；组合根通过共享的 `PinPresenting` 协议接入 Pin。
- 功能通过 `FeatureModule` 提供命令和设置页。共享层不感知具体功能。
- `CaptureSelectionState` 只处理坐标命中、点击 / 拖动和确认状态；`SelectionController` 管理冻结的屏幕覆盖层；`CaptureReviewController` 管理原位标注和导出；`ScreenshotModule` 串联选择、预览与滚动会话。
- `PinStore` 持有会话快照、内容预算和显隐 / 穿透状态；`PinWindowController` 使用带原生标题栏的非激活 `NSPanel` 呈现图片或可直接编辑的纯文本。文字修改即时更新 Pin 自身快照和资源占用，不回写历史条目；每个窗口独立维护原生撤销，输入超预算时保留已接受内容。窗口参考 Preview，隐藏重复标题，使用系统 `NSToolbar` 和居中图片画布；宽度不足 480 pt 时隐藏缩放组，统一从「更多」进入，避免溢出菜单再嵌套「更多」。截图通过最终标注渲染结果创建 Pin，剪贴板直接使用所选条目，不经系统剪贴板中转。截图抑制 token 与用户隐藏状态分开保存；结束、取消和失败统一释放 token。菜单栏独立提供穿透恢复入口。

只在存在实际变化点时引入协议；避免仓储、工厂等无需求的抽象。状态在主线程管理，CPU 密集处理移出 UI 线程。

## 剪贴板历史与置顶（2026-09-23）

本次按三条贯穿 UI 和存储的链路推进：先替换全量 JSON 存取并打通分页读取和内容操作，再接入置顶及拖动排序，最后增加数量输入与确认清理。每条链路完成相关回归后提交。

项目仍在原型阶段，按当前需求和平台实践设计、评审；不承担历史数据兼容，不添加旧格式迁移或兼容解码。当前格式保证应用正常退出、重启后的数据恢复。

- `ClipboardStore` 管理主线程上的采集与操作队列；已接收的写入顺序执行，退出时等待完成。`ClipboardDisk` actor 持有系统 SQLite 连接，使用增量事务保存；不存在自动关闭保存的分支。
- 数据库使用 `STRICT` 表和文本 / 图片内容约束，指纹唯一索引负责去重，排序索引和普通历史的部分索引支持分页及淘汰。日常列表只读 `ClipboardRecord` 摘要，正文由复制、编辑或桌面 Pin 按需读取为 `ClipboardEntry`。缩略图在 actor 内生成；列表每页 100 条，缓存最多五页，最多三个待完成分页请求。搜索覆盖完整历史，旧搜索返回的结果会被丢弃。
- 置顶顺序与修改时间分开。新置顶插在最前，拖动通过相邻 UUID 调整位置；搜索时禁用拖动。重复采集及编辑更新时间但保留置顶顺序；取消置顶按修改时间回到普通历史。编辑成重复内容时合并条目，保留正在编辑条目的身份和任一条目的置顶状态。
- 右键菜单切换置顶，状态徽标叠加在左侧文字 / 图片图标上，不占用正文列。继续使用 AppKit 原生菜单和表格拖动。
- 默认保留 1,000 条普通记录，支持正整数输入且不设产品档位上限；已有明确数量设置继续沿用。置顶不占普通历史名额，原单条和总字节限制取消。缩减数量前展示实际保留 / 删除条数；数据量发生变化时重新确认；取消不改变设置和数据。
- 历史始终保存，关闭记录开关只暂停新增。数据库文件权限为 `0600`，目录为 `0700`；内容未加密。主动删除、清空和数量淘汰均删除对应数据库内容并回收空闲页。桌面 Pin 仍为独立会话快照，资源限制及与显式删除的联动保持不变。

## 原生界面边界

- 设置使用 `NSSplitViewController` 的原生 sidebar item 和 `NSTableView.sourceList`。详情页可滚动，`NSBox` 分组配合系统语义颜色，开关使用 `NSSwitch`。
- 工具箱和剪贴板使用 `NSToolbar`；剪贴板搜索使用 `NSSearchToolbarItem`，唤起面板后直接聚焦搜索。
- `UI.section` 负责内容分组；`UI.glassBar` 只承载浮动操作；相邻玻璃控件置于同一个 `NSGlassEffectContainerView`。列表、图片画布和文本编辑器不叠加玻璃背景。
- 确认选区后直接显示操作栏和标注工具栏，不再切换编辑模式。首次布局按两条工具栏的完整尺寸选择位置并固定锚点，优先放在选区下方，其次上方。添加标注后禁用滚动截图，撤销或清除全部标注后恢复；仅切换工具、颜色或线宽不影响滚动入口。状态提示独立显示在选区边缘，避免编辑和更新提示时移动操作按钮。
- 按钮使用 AppKit 原生 bezel style；截图工具条使用常驻底色的 `accessoryBarAction` 按钮和深色玻璃。完成 / 取消的 SF Symbol 分别使用系统绿色 / 红色，文字保留系统颜色；图标按钮提供 tooltip 和无障碍名称。macOS 27 使用 `effectIsInteractive`，macOS 26 继续使用原生常规玻璃。
- 界面中的应用名由 `AppIdentity` 读取 bundle display name。更名为 superuse 时保留旧 Bundle ID、偏好键与历史路径，不触发数据迁移；打包继续使用原有固定签名证书。

遵循 Liquid Glass 的导航 / 内容分层，以 AppKit 实现，不引入 SwiftUI。API 以当前 Apple 文档和 SDK 为准：

- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)
- [NSGlassEffectContainerView](https://developer.apple.com/documentation/appkit/nsglasseffectcontainerview)
- [NSButton.BezelStyle.glass](https://developer.apple.com/documentation/appkit/nsbutton/bezelstyle-swift.enum/glass)

## 多次采样

- 系统监控菜单栏按文字和指标范围计算紧凑宽度，主指标与附加指标去重组合。展开、关闭与调整采样间隔只调度下一次读取，不清空内核计数器；真实暂停、睡眠和启动才重建基准，取消中的读数结束后再继续。
- 最近最多 10 个快照用于中位数统计；CPU 趋势仍保留 60 个实时样本。无效读数不作为零参与统计，当前指标读取失败时保留不可用状态；tooltip 提供实时值、有效次数和最小 / 最大范围。

- 系统监控 Popover 的根视图和滚动视口不绘制整面不透明底色，外层材质交给 AppKit，避免遮住系统 Liquid Glass。CPU / 内存内容分组保持可读底色，操作按钮继续复用玻璃容器；不在指标后额外叠加玻璃效果。

- 网络速率解析 `NET_RT_IFLIST2` 混合消息时先读取共用的四字节长度 / 版本 / 类型，地址消息按长度跳过，仅对接口统计读取完整 `if_msghdr2`。避免较短的地址消息触发整次读取失败；接口列表增长时有限重试，空闲有效读数为零而非不可用。


## 系统监控桌面窗口（2026-10-09）

- 菜单栏、快捷面板和桌面窗口共用采样器。`monitor.window` 独立配置快捷键；窗口可见时每秒采样，后台默认 5 秒。默认启用最近 24 小时本机历史，关闭记录不删除已有记录；睡眠期间留空。
- 桌面窗口参照系统设置的电池页面，复用设置页的 `NSSplitViewController`：彩色图标侧栏、原生选中态、系统工具栏和无描边内容分组。六项总览按三列两行排列；CPU / 内存进程列表位于图表下方。玻璃只用于导航与控制，图表保持可读底色。
- 曲线使用不会超调的单调三次插值，配合渐变面积、柔光、最新点和可选峰值脉冲。悬停数值与曲线插值一致，缺失段不插值。点击聚合峰值读取原始时间的快照；框选、平移、时间范围、暂停、返回实时和单图展开共用页面状态。
- 低层 SQLite 移至 Shared，由剪贴板与监控各自的 actor 持有独立连接。监控原始记录保留 24 小时、最多 86,401 条；30 秒聚合保留实际采样时长、最小 / 最大、均值和原始峰值时间。短区间及裁切边缘读取原始记录，较老的桌面缓存按桶压缩，退出等待已接收写入。
- libproc 只保存 CPU / 内存各 Top 5 的去重快照：名称、PID、启动时间、CPU 和内存。CPU ticks 按 Mach timebase 转换为纳秒并按整机算力归一化。PID 重用不会串接历史；退出进程可回看已保存数据，未进入 Top 时留空。不保存参数、文件路径或连接明细，不加入网络诊断。
