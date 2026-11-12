# GPO 离线写入实验模型

`tests/unit/ugpowritemodel.pas` 是仅由回归测试引用的纯内存状态模型；不是域写入实现，不被主程序或 GUI 引用。它使用步骤令牌关联回调，检测精确快照变化，区分取消、冲突、未知、部分完成及恢复状态。`tests/unit/unittest.ugpowritemodel.pas` 通过 `tests/openrsattests.lpr` 接入正常控制台测试。

模型是单线程事件合同，无同阶段重试；QWord 溢出和 GUID 生成失败的完整 BeginStep/构造分支尚未故障注入。外部旧 I/O 仍可能在新计划存在时完成，令牌不提供目标级锁定。备份真实性由调用方承诺，恢复核对不是原子条件更新；ABA 和并发修改仍需安全后端解决。快照不证明已包含 ACL、文件身份及所有扩展信息；状态模型尚未接入版本规划，也未实现 INI 修改语义。`ocFail` 必须仅用于确定无副作用的失败，响应丢失属于未知。

`ugpoformats.GpoPlanVersion` 提供独立的纯计算版本规划：用户侧占高 16 位，计算机侧占低 16 位；只递增标记为变更的侧，递增回零时取 1。该规则依据 [MS-GPOL 版本更新](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-gpol/70fd86b1-926a-4dcf-9ce7-6f9d2149c20d)。两侧可同时变更，也可均不变；未变更侧保持原值。返回值同时提供相同 32 位数值的 LDAP 有符号十进制及 GPT 无符号十进制表达。出于保守设计，GPC 与 GPT 基线不一致时拒绝规划，调用方应重新读取并处理复制状态；这不是协议对所有更新情形的一般限制。

此函数不解析或修改 GPT.INI，不执行写入，也不核实版本来源、复制完成或并发状态。输出只是数值计划，不表示可以安全应用到域。

Registry.pol、GPT.INI 与 LDAP 不是天然跨资源原子事务。本模型未实现实际 SMB/LDAP 写入、持久备份/日志、崩溃恢复、线程同步、权限/ACL、GPMC 互操作或多 DC 复制验证；测试通过不构成域写入授权。未来接入前须独立设计并验证完整基线、目标隔离、条件发布与恢复、持久审计和失败查证，并获得适当授权。

## 运行回归测试

按 [tests/README.md](tests/README.md) 注册构建依赖后，在仓库根目录运行：

```powershell
lazbuild --build-mode=test tests\openrsattests.lpi
.\tests\openrsattests.exe --test TUnitTestGpoWriteModel --noenter
```

此模型及版本规划不包含 SYSVOL 访问或域写入实现。独立 Windows 检出验证使用仓库固定的原始子模块版本，不需要未发布的 SessionToken 修改。回归通过不构成实际域写入或跨平台验证。
