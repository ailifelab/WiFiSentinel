本文由CODEX全自动编写。

# 签名与分发说明

当前尚无可直接下载的正式 DMG。已找到可用的 Developer ID Application 身份，但没有找到现有的 notarytool 公证配置；不会新建凭据、导出私钥，或把未公证的包称为完成发行验证的安装包。

当前候选版本为 `0.1 / build 5.3`，仅构建 Apple Silicon（arm64）。最低编译目标为 macOS 13；本轮检查主机为 macOS 27.0.1，不宣称已在更早系统或 Intel 上实测。当前正在使用的应用不因打包而替换或重启。

## 正式发行需要完成什么

1. 从干净、明确的源码提交构建，并通过离线回归。
2. 使用已有 Developer ID Application 身份签名，启用 hardened runtime 和 Apple 安全时间戳；保留应用原有权限声明，不增加绕过系统授权的 entitlement。
3. 用已有公证 profile 提交应用，确认 Apple 返回 Accepted，再 staple 并验证。
4. 将该应用和指向 `/Applications` 的拖拽入口打进 DMG，对 DMG 签名、公证、staple，并检查 Gatekeeper 结果。
5. 核对只读挂载内容、版本、架构、来源提交及文件哈希，再创建对应 Git 标签和 GitHub Release。DMG 与 SHA-256 文件放在 Release 附件中，不进入源码 Git 历史。

缺少公证认证时只能得到本地准备包：即使 Developer ID 签名有效，也不能据此承诺下载后可直接打开。不会用 ad-hoc 签名替代 Developer ID，也不提供关闭系统安全检查的办法。

## 可重复的本地打包

先按 README 构建，并对候选 `.app` 使用自己的已有身份完成 Developer ID 签名。`scripts/package_dmg.py` 接收这个已签名的应用，制作含 Applications 拖拽入口的 DMG，并生成校验与本地检查记录：

```sh
WIFISENTINEL_SIGN_IDENTITY='Developer ID Application: YOUR EXISTING IDENTITY' \
  python3 scripts/package_dmg.py \
  build/candidates/rewrite5-exit0/WiFiSentinel.app dist
```

该脚本不会公证、启动应用、安装应用或上传发布；生成的文件明确带 `unnotarized` 标记。`dist/` 不纳入 Git。公证完成后还必须重新检查、生成最终校验文件，才能作为发行附件。

签名、公证和联网恢复是不同验证。软件的恢复能力限制仍以[验证范围](VALIDATION.md)为准。
