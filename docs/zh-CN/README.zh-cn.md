# OpenRSAT 中文维护版

OpenRSAT 是一个使用 Object Pascal/Lazarus 编写的 Active Directory 管理工具，界面和使用方式接近 Microsoft RSAT。它可在 Windows、Linux 和 macOS 上运行，用于管理用户、计算机、组、OU、DNS、站点和服务等 AD 对象。

本仓库基于上游 OpenRSAT 0.4.594，保留最新功能，并维护额外的简体中文选项、批量操作、Windows 构建和 macOS arm64 构建。上游功能介绍见 [README.md](../../README.md)，构建步骤见 [build.zh-cn.md](./build.zh-cn.md)。

## 下载

发布包会放在 GitHub Releases 中：

- `OpenRSAT-win64.zip`：Windows 64 位版本，包含 `OpenRSAT.exe`。
- `OpenRSAT-macos-arm64.zip`：Apple Silicon / macOS arm64 版本，包含 `OpenRSAT.app` 和 `fix-and-open.command`。

下载时请核对 Release 的版本说明。仓库内现有的 `dist/OpenRSAT-macos-arm64.zip` 是历史构建，未包含本次上游 0.4.594 合并和增强；本次尚未重新构建或验证 macOS 包。

Windows 版本解压后保留同级 `locale` 目录，直接运行 `OpenRSAT.exe`。如果重新覆盖旧版本，请先关闭正在运行的 OpenRSAT，否则 Windows 可能会拒绝写入 exe。

macOS 版本首次运行时请保持 `OpenRSAT.app` 和 `fix-and-open.command` 在同一目录。如果系统提示无法验证应用，可以运行 `fix-and-open.command`，脚本会移除隔离属性、执行本机 ad-hoc 签名并打开应用。更详细说明见 [macos-signing.zh-cn.md](./macos-signing.zh-cn.md)。

## 当前中文增强

- 使用上游的语言切换和外置 PO 目录机制，新增可见的“简体中文”选项；英语、法语、希腊语和波兰语选项保留，默认跟随系统语言。
- 增加并修正简体中文界面文本，覆盖主菜单、右键菜单、对象属性页、搜索页、BitLocker、LAPS 等常用入口。
- 补充上游新增的精细密码策略、GPO 属性及链接、站点复制计划、全局编录、对象选择器和新版 LAPS 界面翻译。
- 列表中的常见对象类型和默认描述会显示为中文，例如“计算机”“组织单位”“容器”等。
- 增加“查找 BitLocker 恢复密码”入口，可按恢复密钥 ID 前 8 位搜索。
- 多域控制器计算机删除可在选项中启用，并指定域控制器范围；执行前展示对象和控制器列表，执行后逐项报告结果。
- 增加“批量移动到 OU...”入口，支持选中两个以上对象后批量移动到目标 OU/容器。
- 对象列表和搜索结果均支持批量删除，一次确认完整范围后逐项执行，失败项会保留错误信息。
- 修复 Windows 下右键菜单弹出时批量移动动作保持禁用的问题。

## 功能概览

- 用户和计算机：浏览 OU/容器树，管理用户、组、计算机、联系人等对象。
- 搜索：按名称、属性条件或 LDAP 过滤器搜索对象，并可从结果中打开属性、定位、删除、批量移动。
- 对象属性：查看和编辑常规属性、安全、成员关系、LAPS、BitLocker 恢复信息等。
- DNS：通过 LDAP 管理 AD DNS 区域和记录。
- 站点和服务：管理站点、子网、服务器和复制相关对象。
- 服务和接口：查看 AD 中的服务连接点等对象。

## 批量移动到 OU 和删除

1. 在“用户和计算机”的对象列表或搜索结果中，使用 Ctrl/Shift 多选对象。
2. 选择“批量移动到 OU...”，选定目标 OU/容器，核对目标路径后确认。此操作移动已选对象，也支持移动 OU 本身；目标不能是已选对象本身或其子级。
3. 要批量删除，选择“删除”，核对确认框中的对象列表。删除 OU/容器会同时删除其中的子对象。
4. 操作完成后查看逐项结果。部分失败不会撤销已经成功的操作；修正权限、目标冲突等问题后，仅重试失败对象。

移动和删除继续使用当前连接账户的目录权限，不会自动解除“防止意外删除”保护。移动可能改变继承的组策略和权限；删除计算机对象会影响其域信任关系。

## 多域控制器计算机删除设置

在“文件 → 选项 → 用户和计算机”中向下滚动到“启用多域控制器计算机删除”：

- 默认关闭。启用后使用独立的多域控制器删除菜单；普通“删除”的行为不变。
- 域控制器完整 DNS 主机名每行一个，例如 `dc1.example.com`、`dc2.example.com`；必须与当前域发现的可写域控制器名称匹配（不区分大小写）。留空时使用当前域发现的所有可写域控制器。
- 保存设置后，在对象列表或搜索结果中选择一个或多个计算机，使用“从所选域控制器批量删除计算机...”入口。执行前核对确认框中的计算机及域控制器范围，确认范围包含计算机的子对象。
- 仅接受当前域的可写域控制器，以及工作站/成员服务器计算机对象；域控制器账户和无法验证身份的对象会被拒绝。
- 完成后按“计算机 × 域控制器”检查结果；“已不存在”可能表示该删除已通过 AD 复制到达该控制器，连接或权限错误会分别报告。

程序最多同时处理 4 个域控制器，控制器之间使用独立连接；每个控制器内按所选计算机逐项处理。对象以 GUID 验证身份，避免把原路径下重新创建的同名计算机当作已选对象删除。

设置只控制本次直接发出删除请求的控制器。AD 删除仍会在域内复制；关闭此设置、移除某个控制器或取消后续操作，都不能恢复已删除的对象。多个控制器上的请求不是事务，可能部分成功。需恢复对象时按所在域的备份或 AD 回收站流程处理。

配置保存在既有配置文件的 `[ADUC]` 节中：`EnableMultiDCDelete` 为开关，`DeleteDomainControllers` 为分号分隔的主机名。界面会把它显示为每行一个主机名。

## 中文界面

默认采用上游的系统语言行为，不强制中文。在“文件 → 选项 → 全局”（英文界面为 File → Options → Global）中将语言设为“简体中文”，保存并按提示重启。英语 `en`、法语 `fr`、希腊语 `el` 和波兰语 `pl` 仍可选择；空选项表示系统默认。旧配置中的 `zh`、`zh_CN` 和 `zh-CN` 均可加载简体中文。中文 OU、对象名称和属性值保留原始内容，界面翻译不会重命名目录对象。

翻译统一维护在 `languages/OpenRSAT.zh.po`，与上游 `OpenRSAT.en.po` 等目录并列。Windows 发布包将这些 PO 文件放在 `OpenRSAT.exe` 同级的 `locale` 目录；macOS 放在 `OpenRSAT.app/Contents/Resources/locale`；Linux 安装到 `/usr/share/openrsat/locale`。修改 PO 后同步发布包中的对应文件并重新启动程序即可，不再使用内嵌 `Translation.zh.po` 资源。模板更新使用上游 `update_language.py`。

## 验证范围

合并上游 0.4.594 后，2026-11-11 在 Windows 64 位、FPC 3.2.2 下完成 91 项离线断言：DN 与批量顺序处理 32 项、ADUC 选项持久化 8 项、域控范围与计算机身份检查 30 项、上游双列表选择逻辑 13 项、系统默认与中文等语言保存/重载 8 项，全部通过。复现命令见 [测试说明](../../tests/README.md)。这些测试不连接 AD，也不代表已验证实际删除或复制行为。

真实目录中的权限、删除保护、中文 DN、复制延迟和不可达域控制器行为，需要在隔离的 AD 测试域中验收。测试时先使用专用 OU 和临时计算机对象；离线测试不能替代实际域环境验证。

## 已知注意事项

- 当前 macOS 包使用 ad-hoc 签名，不是 Apple Developer ID 签名，也未做 notarization；适合内部使用和自测。
- Windows 与 macOS 的 Lazarus/LCL 菜单刷新时机不同，Windows 右键菜单相关动作已经做了显式刷新处理。
- 构建日志里可能出现 Lazarus 包宏、重复资源文件或语言资源扫描提示，只要最终完成 `Linking ... OpenRSAT.exe`，通常不影响产物生成。

## 构建

Windows win64 构建：

```powershell
C:\lazarus\lazbuild.exe sources\OpenRSAT.lpi --bm=win64
New-Item -ItemType Directory -Force bin\win64\locale | Out-Null
Copy-Item languages\OpenRSAT.*.po bin\win64\locale\
```

输出位置：

```text
bin/win64/OpenRSAT.exe
```

重新编译并按构建文档打包后，macOS arm64 包输出为（仓库已有同名文件仍为历史版本）：

```text
dist/OpenRSAT-macos-arm64.zip
```
