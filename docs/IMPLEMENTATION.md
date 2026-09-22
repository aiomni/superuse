# 实现路径

superuse 是 macOS 26+ 菜单栏应用。macOS 原生桌面 UI 使用 **AppKit**；UIKit 属于 iOS / Mac Catalyst。本项目不使用 SwiftUI，以 NSGlassEffectView、NSWindow、NSTableView、NSTextView 等原生组件实现。

## Tracer Bullets

1. 应用启动 → 菜单栏 → 全局快捷键 → 统一设置。先验证宿主和命令路由。
2. 系统剪贴板 → 有界历史 → 快捷面板 → 复制 / 回到来源应用粘贴 → 编辑。
3. 一个截图快捷键 → 定格屏幕 → 自动识别全屏 / 窗口或拖动选区 → 原位预览、标注与导出。
4. 在预览操作栏进入滚动 → 手动滚动采样 → 重叠检测 → 有界拼接 → 回到原位预览。
5. 构建、核心算法测试、原生 UI 验证和使用文档。

每条链路构建通过后提交。没有外部服务和第三方依赖。

四条功能链路已经实现，并完成 Release 打包、核心测试和 AppKit 集成测试。截图只暴露一个命令，保留原区域截图命令的 ID 以兼容已保存的快捷键。预览和标注复用同一覆盖层，不再另开编辑窗口。

## 边界

- `SuseCore`：可测试的数据模型、纯算法，与 AppKit 生命周期隔离。
- `App`：组合根、菜单栏、工具箱、统一设置窗口。
- `LoginItemSettingsView` 通过 `SMAppService.mainApp` 管理当前应用的登录项，以系统状态为准，不另存 UserDefaults 开关；注册失败恢复实际状态，等待批准时提供系统设置入口。`LoginItemService` 隔离系统调用，测试替身不会注册真实登录项。`AppLaunchContext` 识别系统登录启动事件，保留菜单栏功能并跳过工具箱自动展示。
- `Shared`：功能接口、快捷键注册、设置存储和少量原生 UI 工具。
- `Features/Clipboard`、`Features/Screenshot`：各自持有状态、UI、服务，不相互调用。
- 功能通过 `FeatureModule` 提供命令和设置页。共享层不感知具体功能。
- `CaptureSelectionState` 只处理坐标命中、点击 / 拖动和确认状态；`SelectionController` 管理冻结的屏幕覆盖层；`CaptureReviewController` 管理原位标注和导出；`ScreenshotModule` 串联选择、预览与滚动会话。

只在存在实际变化点时引入协议；避免仓储、工厂等无需求的抽象。状态在主线程管理，CPU 密集处理移出 UI 线程。

## 原生界面边界

- 设置使用 `NSSplitViewController` 的原生 sidebar item 和 `NSTableView.sourceList`。详情页可滚动，`NSBox` 分组配合系统语义颜色，开关使用 `NSSwitch`。
- 工具箱和剪贴板使用 `NSToolbar`；剪贴板搜索使用 `NSSearchToolbarItem`，唤起面板后直接聚焦搜索。
- `UI.section` 负责内容分组；`UI.glassBar` 只承载浮动操作；相邻玻璃控件置于同一个 `NSGlassEffectContainerView`。列表、图片画布和文本编辑器不叠加玻璃背景。
- 截图操作栏首次布局按标注工具展开后的尺寸选择位置并固定锚点；选区下方有空间时向下展开，否则向上展开。编辑按钮预留两种标题的宽度，状态提示保持单行，避免切换编辑或更新提示时移动操作按钮。
- 按钮使用 AppKit 原生 bezel style；工具条按钮通过 `showsBorderOnlyWhileMouseInside` 显示原生悬停反馈。完成 / 取消的 SF Symbol 分别使用系统绿色 / 红色，文字保留系统颜色；图标按钮提供 tooltip 和无障碍名称。macOS 27 使用 `effectIsInteractive`，macOS 26 继续使用原生常规玻璃。
- 界面中的应用名由 `AppIdentity` 读取 bundle display name。更名为 superuse 时保留旧 Bundle ID、偏好键与历史路径，不触发数据迁移；打包继续使用原有固定签名证书。

遵循 Liquid Glass 的导航 / 内容分层，以 AppKit 实现，不引入 SwiftUI。API 以当前 Apple 文档和 SDK 为准：

- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)
- [NSGlassEffectContainerView](https://developer.apple.com/documentation/appkit/nsglasseffectcontainerview)
- [NSButton.BezelStyle.glass](https://developer.apple.com/documentation/appkit/nsbutton/bezelstyle-swift.enum/glass)
