# GPO 离线写入实验模型

`tests/unit/ugpowritemodel.pas` 是仅由回归测试引用的纯内存状态模型；不是域写入实现，不被主程序或 GUI 引用。它使用步骤令牌关联回调，检测精确快照变化，区分取消、冲突、未知、部分完成及恢复状态。`tests/unit/unittest.ugpowritemodel.pas` 通过 `tests/openrsattests.lpr` 接入正常控制台测试。

模型是单线程事件合同，无同阶段重试；QWord 溢出和 GUID 生成失败的完整 BeginStep/构造分支尚未故障注入。外部旧 I/O 仍可能在新计划存在时完成，令牌不提供目标级锁定。备份真实性由调用方承诺，恢复核对不是原子条件更新；ABA 和并发修改仍需安全后端解决。快照不证明已包含 ACL、文件身份及所有扩展信息，也未实现 GPC/GPT 版本递增、半字规则及 INI 语义。`ocFail` 必须仅用于确定无副作用的失败，响应丢失属于未知。

Registry.pol、GPT.INI 与 LDAP 不是天然跨资源原子事务。本模型未实现实际 SMB/LDAP 写入、持久备份/日志、崩溃恢复、线程同步、权限/ACL、GPMC 互操作或多 DC 复制验证；测试通过不构成域写入授权。未来接入前须独立设计并验证完整基线、目标隔离、条件发布与恢复、持久审计和失败查证，并获得适当授权。

## 运行回归测试

按 [tests/README.md](tests/README.md) 注册构建依赖后，在仓库根目录运行：

```powershell
lazbuild --build-mode=test tests\openrsattests.lpi
.\tests\openrsattests.exe --test TUnitTestGpoWriteModel --noenter
```

此节点只包含文件格式辅助代码与纯内存实验模型，不包含 GPO 界面、SYSVOL 访问或域写入实现。独立 Windows 检出验证使用仓库固定的原始子模块版本，不需要未发布的 SessionToken 修改。模型 509 项断言、该节点完整离线控制台 1106 项断言通过；这不是实际域写入或跨平台验证。
