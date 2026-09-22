# 实现路径

Suse 是 macOS 26+ 菜单栏应用。macOS 原生桌面 UI 使用 **AppKit**；UIKit 属于 iOS / Mac Catalyst。本项目不使用 SwiftUI，以 NSGlassEffectView、NSWindow、NSTableView、NSTextView 等原生组件实现。

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
- `Shared`：功能接口、快捷键注册、设置存储和少量原生 UI 工具。
- `Features/Clipboard`、`Features/Screenshot`：各自持有状态、UI、服务，不相互调用。
- 功能通过 `FeatureModule` 提供命令和设置页。共享层不感知具体功能。
- `CaptureSelectionState` 只处理坐标命中、点击 / 拖动和确认状态；`SelectionController` 管理冻结的屏幕覆盖层；`CaptureReviewController` 管理原位标注和导出；`ScreenshotModule` 串联选择、预览与滚动会话。

只在存在实际变化点时引入协议；避免仓储、工厂等无需求的抽象。状态在主线程管理，CPU 密集处理移出 UI 线程。
