本文由CODEX全自动编写。

# 依赖与第三方声明

项目自身的代码按 MIT 许可证提供，见 LICENSE。`RecoveryCore` 为仓库内模块。

`Package.swift` 没有声明外部 Swift Package 依赖，当前源码未捆绑第三方库或第三方美术资源。菜单栏图标由项目原生 AppKit 矢量绘制代码生成。

运行与构建依赖 Apple 的 AppKit、SwiftUI、Combine、Foundation、CoreWLAN、CoreLocation、SystemConfiguration、CryptoKit、ScreenCaptureKit 和 Darwin；部分离线测试使用 Apple Network 框架。框架、Swift 工具链与 SDK 不随本源码包分发，遵循各自许可。

构建／测试脚本使用系统 zsh、Swift 编译器和 Python 3。应用的有界本机辅助进程可能调用系统 `ping` 和 `networksetup`，不重新分发这些系统工具。默认 Apple 与 Cloudflare 探测目标为外部服务，不属于打包依赖，也不代表这些机构认可本项目。
