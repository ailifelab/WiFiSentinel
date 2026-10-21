本文由CODEX全自动编写。

# 签名与分发说明

[0.1 / build 5.3 正式发行](https://github.com/ailifelab/WiFiSentinel/releases/tag/v0.1-build5.3)提供 Apple Silicon（arm64）DMG 和同名 SHA-256 文件。二进制只放在 Release 附件中，不进入源码 Git 历史。

## 本次发行检查

2026-10-21 在 macOS 27.0.1 上完成：

| 检查 | 结果 |
| --- | --- |
| 应用签名 | Developer ID Application；hardened runtime 与 Apple 安全时间戳；严格签名校验通过 |
| 应用公证 | Apple 返回 Accepted；票据已附加并验证 |
| DMG 签名与公证 | Developer ID 签名；Apple 返回 Accepted；票据已附加并验证 |
| Gatekeeper | 应用执行评估、DMG 打开评估均为 accepted，来源为 Notarized Developer ID |
| 挂载内容 | 只读挂载逐文件核对通过，包含应用、指向 `/Applications` 的拖拽入口及安装与许可证说明 |
| 架构与系统 | arm64；最低编译目标 macOS 13；本轮主机 macOS 27.0.1 |

正式签名开发者：`Sherard Lee (75MD457NV7)`。

- 构建源码：[`8dbfa3d6a466a8ed683874183a326cd901971723`](https://github.com/ailifelab/WiFiSentinel/commit/8dbfa3d6a466a8ed683874183a326cd901971723)，版本标签 `v0.1-build5.3` 指向该提交。
- 附件：`WiFiSentinel-0.1-build5.3-macos-arm64.dmg`，551,110 字节。
- DMG SHA-256（附加公证票据之后计算）：`12e6754aa665a9bd002aac7cfd939bddb3bc6c0a6dd979544410823414953c2b`。

没有为打包替换或重启当前运行的应用，也没有改变用户网络、自动恢复开关或系统安全权限。没有在本轮对该候选执行首次安装和正常启动，因此不把包的静态分发检查当成实机运行或网络恢复测试。Intel、较早 macOS 和其他设备仍未实机验证。

## 开发者打包流程

正式发行应从干净、明确的提交构建并完成离线回归，保留 `BuildInfo.json` 中的来源记录：

1. 使用自己的已有 Developer ID Application 身份签名应用，启用 hardened runtime 和 Apple 安全时间戳，保留必要的原有权限声明。
2. 将已签名应用打成保留应用目录的 ZIP，通过已有的 `notarytool` profile 提交 Apple 公证。确认 Accepted 后，对应用运行 `stapler staple`、`stapler validate` 并校验签名和 Gatekeeper。
3. 将已附加票据的应用、Applications 快捷入口、正常安装说明和许可证制作成 DMG，正式签名后单独提交 DMG 公证。确认 Accepted 后再次附加并验证票据。
4. 只读挂载最终 DMG，核对全部内容、应用签名和票据；分别评估应用与 DMG 的 Gatekeeper 结果。最后计算校验文件，发布与构建来源对应的标签和 Release 附件。

认证密码只能在本机安全交互输入，不应写入脚本、日志、环境变量或源码。没有有效 Developer ID 或公证条件时，应如实保留准备包，不关闭系统安全检查或以 ad-hoc 冒充正式签名。

仓库的 `scripts/package_dmg.py` 仍是**本地准备工具**：接收已签名应用，生成带 `unnotarized` 标记的 DMG、校验和检查记录，不提交公证、不启动、不安装、不上传。它生成的准备包不能直接作为正式发行包；本次正式包另行完成了上述完整流程，并使用正常的安装说明。`build/` 与 `dist/` 不纳入 Git。

签名、公证和联网恢复是不同验证，恢复能力限制仍以[验证范围](VALIDATION.md)为准。
