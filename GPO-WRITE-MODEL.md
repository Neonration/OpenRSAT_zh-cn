# GPO 离线写入实验模型

`tests/unit/ugpowritemodel.pas` 是仅由回归测试引用的纯内存状态模型；不是域写入实现，不被主程序或 GUI 引用。它使用步骤令牌关联回调，检测精确快照变化，区分取消、冲突、未知、部分完成及恢复状态。`tests/unit/unittest.ugpowritemodel.pas` 通过 `tests/openrsattests.lpr` 接入正常控制台测试。

模型是单线程事件合同，无同阶段重试；QWord 溢出和 GUID 生成失败的完整 BeginStep/构造分支尚未故障注入。外部旧 I/O 仍可能在新计划存在时完成，令牌不提供目标级锁定。备份真实性由调用方承诺，恢复核对不是原子条件更新；ABA 和并发修改仍需安全后端解决。快照不证明已包含 ACL、文件身份及所有扩展信息；状态模型尚未接入版本规划或 INI 候选生成。`ocFail` 必须仅用于确定无副作用的失败，响应丢失属于未知。

`ugpoformats.GpoPlanVersion` 提供独立的纯计算版本规划：用户侧占高 16 位，计算机侧占低 16 位；只递增标记为变更的侧，递增回零时取 1。该规则依据 [MS-GPOL 版本更新](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-gpol/70fd86b1-926a-4dcf-9ce7-6f9d2149c20d)。两侧可同时变更，也可均不变；未变更侧保持原值。返回值同时提供相同 32 位数值的 LDAP 有符号十进制及 GPT 无符号十进制表达。出于保守设计，GPC 与 GPT 基线不一致时拒绝规划，调用方应重新读取并处理复制状态；这不是协议对所有更新情形的一般限制。

此函数不解析或修改 GPT.INI，不执行写入，也不核实版本来源、复制完成或并发状态。输出只是数值计划，不表示可以安全应用到域。

`ugpoformats.GpoBuildGptIniCandidate` 根据原始字节、期望旧版本和新版本生成独立内存候选；输入和输出必须是不同变量。只替换 `[General]` 中 `Version` 值的十进制数字，保留其余字节、BOM、空格和逐行换行方式。版本不符、缺失、非法或重复节/键时拒绝；比较名称时忽略大小写，符合 [MS-GPOL 的 INI 唯一性要求](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-gpol/b0e5c9e8-e858-4a7a-a94a-4a3d0a9d87a2)。失败输出为空，文件不被读写。

候选生成刻意只支持内容为 ASCII 的无 BOM、UTF-8 BOM 和 UTF-16LE BOM 文本；非 ASCII 内容、UTF-16BE 或其他不确定编码拒绝，不能据此判断原文件无效。MS-GPOL 指定 ANSI 编码；两种 BOM 格式是本项目的离线兼容处理，不代表协议兼容性已验证。节名仅接受字母、数字、下划线、空格和连字符，键名接受字母、数字、下划线和连字符；未知节、键及 ASCII 值原样保留，其他格式拒绝。此限制比只读解析器严格，目的是在字节边界和唯一性无法确定时不生成候选；不是微软协议对所有合法文件的限制。

`ugpoformats.GpoBuildOfflinePlan` 将这两项能力组合为纯内存计划。调用方须提供 GPC 和 GPT 原始版本、原始 GPT.INI，以及用户侧和计算机侧各自的原始与候选 Registry.pol 字节；四份策略文件都必须存在且能被解析，文件缺失与空策略并不等同。输入不得引用输出计划的字段，调用期间不得并发修改输入。函数按完整字节比较判断各侧是否变更，仅递增变更侧；两侧均未变更时保留原版本和原始 INI 字节。通过校验后返回独立副本，任何失败均不返回部分计划。

该计划只校验所提供的数据与数值一致，不验证文件身份、权限、ACL、版本读取时效、并发或复制，也不证明可安全写域；它未连接实验状态模型或执行任何文件、LDAP、SMB 操作。

Registry.pol、GPT.INI 与 LDAP 不是天然跨资源原子事务。本模型未实现实际 SMB/LDAP 写入、持久备份/日志、崩溃恢复、线程同步、权限/ACL、GPMC 互操作或多 DC 复制验证；测试通过不构成域写入授权。未来接入前须独立设计并验证完整基线、目标隔离、条件发布与恢复、持久审计和失败查证，并获得适当授权。

## 运行回归测试

按 [tests/README.md](tests/README.md) 注册构建依赖后，在仓库根目录运行：

```powershell
lazbuild --build-mode=test tests\openrsattests.lpi
.\tests\openrsattests.exe --test TUnitTestGpoWriteModel --noenter
```

此模型及版本规划不包含 SYSVOL 访问或域写入实现。独立 Windows 检出验证使用仓库固定的原始子模块版本，不需要未发布的 SessionToken 修改。回归通过不构成实际域写入或跨平台验证。
