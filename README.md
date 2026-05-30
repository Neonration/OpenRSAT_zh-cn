# OpenRSAT 中文版

OpenRSAT 是一个使用 Object Pascal/Lazarus 编写的 Active Directory 管理工具，界面和使用方式接近 Microsoft RSAT。它可以在 Windows、Linux 和 macOS 上运行，用于管理用户、计算机、DNS、站点和服务等 AD 对象。

本仓库是中文本地化和 macOS arm64 打包维护版本。英文原文文档保留在 [`README.en.md`](./README.en.md)，中文构建说明见 [`build.zh-cn.md`](./build.zh-cn.md)。

## 功能概览

- 用户和计算机：浏览 OU/容器树，管理用户、组、计算机等对象。
- DNS：通过 LDAP 管理 AD DNS 区域和记录。
- 站点和服务：管理站点、子网和相关对象。
- 服务和接口：查看 AD 中的服务对象。
- 对象属性：查看和编辑常用属性、安全信息、LAPS、BitLocker 等。
- 搜索：在 AD 中搜索对象。

## macOS arm64 包

Apple Silicon 版本发布包位于：

[`dist/OpenRSAT-macos-arm64.zip`](./dist/OpenRSAT-macos-arm64.zip)

压缩包内包含：

- `OpenRSAT.app`
- `fix-and-open.command`

在其他 Mac 上使用时：

1. 解压 `OpenRSAT-macos-arm64.zip`。
2. 保持 `OpenRSAT.app` 和 `fix-and-open.command` 在同一个目录。
3. 如果 macOS 提示无法验证应用，双击或在终端执行 `fix-and-open.command`。
4. 脚本会移除隔离属性、重新做本机 ad-hoc 签名、校验签名并打开应用。

首次运行和签名脚本的单独说明见 [`macos-signing.zh-cn.md`](./macos-signing.zh-cn.md)。

应用包已经内置 OpenSSL 1.1 动态库，路径为 `OpenRSAT.app/Contents/MacOS/lib`，正常情况下不需要单独安装 OpenSSL。

注意：当前签名是 ad-hoc 签名，不是 Apple Developer ID 公证签名。内部测试和自用可以使用该脚本处理 Gatekeeper 拦截；正式分发建议使用 Developer ID 签名和 notarization。

## 中文显示

本仓库默认语言维护为中文。macOS 版本已处理资源路径和默认语言配置，使应用启动后优先加载中文翻译资源。

如果出现界面仍显示英文，优先检查：

- `languages/*.zh.po` 是否随源码存在。
- `sources/OpenRSAT.lpi` 中资源路径是否使用类 Unix 路径。
- 用户配置中是否保存了旧语言选项。

## 构建

完整构建步骤见 [`build.zh-cn.md`](./build.zh-cn.md)。

macOS arm64 本地构建输出通常位于：

`bin/macosx-arm64/OpenRSAT`

可分发包输出位于：

`dist/OpenRSAT-macos-arm64.zip`
