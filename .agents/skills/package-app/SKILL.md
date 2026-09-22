---
name: package-app
description: 在本仓库构建、签名并验证 superuse 的 macOS App。用于打包 App、生成 Release 或 Debug 应用包、排查打包与代码签名失败；复用仓库脚本和现有固定证书。
---

# 打包 superuse

生成可运行的 `dist/superuse.app`。以仓库现有配置为准，复用 [scripts/build-app.sh](../../../scripts/build-app.sh)，不要另写一套打包或签名流程。

## 构建前

- 在包含 `Package.swift` 的仓库根目录执行下面的命令。构建需要 macOS、Xcode 27+ / Swift 6.4；应用最低支持 macOS 26。
- 先查看打包脚本、[Package.swift](../../../Package.swift) 和 [Info.plist](../../../Resources/Info.plist)，确认产物与工具链要求没有变化。怀疑工具链选择错误时，检查 `xcode-select -p`、`xcodebuild -version` 和 `swift --version`。
- 如果正在运行即将覆盖的 `dist/superuse.app`，先正常退出该开发实例，让剪贴板历史完成保存。不要按进程名称批量结束其他安装路径的应用。

## 固定签名

脚本优先使用环境变量 `SIGNING_IDENTITY`，其次使用仓库根目录的 `.signing-identity.local`。沿用已有配置；不要覆盖本机配置或把它加入 Git。

缺少配置时，先查看当前钥匙串内可用的代码签名身份：

```sh
security find-identity -v -p codesigning
```

签名身份必须包含可用的私钥。当前开发证书名称为 `Suse Local Development`，应用更名后仍复用该证书。首次配置可从 [.signing-identity.example](../../../.signing-identity.example) 复制模板，填写实际证书的 SHA-1 或完整名称；优先用 SHA-1 区分同名证书。也可以仅对本次构建指定身份：

```sh
SIGNING_IDENTITY='Suse Local Development' ./scripts/build-app.sh release
```

保留 Bundle ID `app.suse.mac` 和现有证书身份。代码内容改变会改变 CDHash，但不应改变绑定证书的 designated requirement。不要因为品牌名称已变成 superuse 就重建同名证书、修改 Bundle ID，或改用 ad-hoc 签名。签名失败时报告具体错误与缺失条件，不通过重置系统隐私权限或降级签名绕过失败。

## 打包

默认按用户交付需求构建 Release，显式传入配置；脚本省略参数时实际上构建 Debug：

```sh
./scripts/build-app.sh release
```

用户需要调试产物时运行：

```sh
./scripts/build-app.sh debug
```

脚本会编译 `superuse` executable product、创建 `.app` 目录、复制 Info.plist、生成 `.icns` 图标，并用固定身份签名和验证。两种配置都写入 `dist/superuse.app`，后一次覆盖前一次。默认构建当前主机架构，不能未经检查就声称产物是 Universal。

任务包含代码修改时运行与改动相关的测试；完整回归使用 `swift test`。仅整理打包说明时无需重跑应用测试，也无需重新打包或中断正在运行的应用。

## 验证与交付

脚本退出成功后检查产物；失败时不要把上一次残留的 App 当作本次成功结果：

```sh
test -x dist/superuse.app/Contents/MacOS/superuse
plutil -lint dist/superuse.app/Contents/Info.plist
codesign --verify --deep --strict dist/superuse.app
codesign -d -r- dist/superuse.app
file dist/superuse.app/Contents/MacOS/superuse
```

确认名称与可执行文件为 `superuse`、Bundle ID 为 `app.suse.mac`，签名 requirement 绑定所选证书。仅有 identifier 条件不足以确认固定签名身份。

交付时给出 App 的绝对路径链接、构建配置、签名验证结果，以及实际执行的测试。`dist/`、`.build/` 和 `.signing-identity.local` 均不提交。

产物默认留在 `dist/`。任务同时要求运行或安装时，再处理启动或替换目标安装路径；启动使用 App bundle，避免直接运行裸 executable 导致权限身份混淆。当前流程生成本机自用签名包，不包含 Developer ID 公证或对外发布；相关身份与权限说明见 [README](../../../README.md#构建与运行)。
