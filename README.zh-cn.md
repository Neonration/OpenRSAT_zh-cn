# OpenRSAT 中文维护版

OpenRSAT 是一个使用 Object Pascal/Lazarus 编写的 Active Directory 管理工具，界面和使用方式接近 Microsoft RSAT。它可在 Windows、Linux 和 macOS 上运行，用于管理用户、计算机、组、OU、DNS、站点和服务等 AD 对象。

本仓库维护 OpenRSAT 的简体中文本地化、Windows 构建和 macOS arm64 构建。英文原文文档保留在 [README.en.md](./README.en.md)，构建步骤见 [build.zh-cn.md](./build.zh-cn.md)。

## 下载

发布包会放在 GitHub Releases 中：

- `OpenRSAT-win64.zip`：Windows 64 位版本，包含 `OpenRSAT.exe`。
- `OpenRSAT-macos-arm64.zip`：Apple Silicon / macOS arm64 版本，包含 `OpenRSAT.app` 和 `fix-and-open.command`。

Windows 版本解压后直接运行 `OpenRSAT.exe`。如果重新覆盖旧版本，请先关闭正在运行的 OpenRSAT，否则 Windows 可能会拒绝写入 exe。

macOS 版本首次运行时请保持 `OpenRSAT.app` 和 `fix-and-open.command` 在同一目录。如果系统提示无法验证应用，可以运行 `fix-and-open.command`，脚本会移除隔离属性、执行本机 ad-hoc 签名并打开应用。更详细说明见 [macos-signing.zh-cn.md](./macos-signing.zh-cn.md)。

## 当前中文增强

- 增加并修正简体中文界面文本，覆盖主菜单、右键菜单、对象属性页、搜索页、BitLocker、LAPS 等常用入口。
- 列表中的常见对象类型和默认描述会显示为中文，例如“计算机”“组织单位”“容器”等。
- 增加“查找 BitLocker 恢复密码”入口，可按恢复密钥 ID 前 8 位搜索。
- 增加“从所有域控制器删除计算机”入口，执行前会展示域控制器列表并要求确认。
- 增加“批量移动到 OU...”入口，支持选中两个以上对象后批量移动到目标 OU/容器。
- 修复 Windows 下右键菜单弹出时批量移动动作保持禁用的问题。

## 功能概览

- 用户和计算机：浏览 OU/容器树，管理用户、组、计算机、联系人等对象。
- 搜索：按名称、属性条件或 LDAP 过滤器搜索对象，并可从结果中打开属性、定位、删除、批量移动。
- 对象属性：查看和编辑常规属性、安全、成员关系、LAPS、BitLocker 恢复信息等。
- DNS：通过 LDAP 管理 AD DNS 区域和记录。
- 站点和服务：管理站点、子网、服务器和复制相关对象。
- 服务和接口：查看 AD 中的服务连接点等对象。

## 已知注意事项

- 当前 macOS 包使用 ad-hoc 签名，不是 Apple Developer ID 签名，也未做 notarization；适合内部使用和自测。
- Windows 与 macOS 的 Lazarus/LCL 菜单刷新时机不同，Windows 右键菜单相关动作已经做了显式刷新处理。
- 构建日志里可能出现 Lazarus 包宏、重复资源文件或语言资源扫描提示，只要最终完成 `Linking ... OpenRSAT.exe`，通常不影响产物生成。

## 构建

Windows win64 构建：

```powershell
C:\lazarus\lazbuild.exe sources\OpenRSAT.lpi --bm=win64
```

输出位置：

```text
bin/win64/OpenRSAT.exe
```

macOS arm64 构建输出通常为：

```text
dist/OpenRSAT-macos-arm64.zip
```
