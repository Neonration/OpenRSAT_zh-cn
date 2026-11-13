# IGroupPolicyObject 隔离域实验原型

**状态：真实域 `Save` 尚未调用，也未验证写入结果。** 2026-11-13 经明确授权，在隔离域创建了一个专用、未链接的测试 GPO。首次检查因新建 GPT.INI 含 CP936 中文且原型只支持 ASCII 而停止，未进入保存；两条默认 GPO 的快照前后相同。修复本地版本解析后，独立只读核对显示测试 GPO 的对象身份、元数据和文件哈希未变、域及站点链接数为零。

官方 COM 类使用单线程单元；远程 PowerShell 会话是 MTA，直接调用返回 `E_NOINTERFACE`。在 STA 线程只读打开后，接口返回的 LDAP 路径不含域控主机名，SYSVOL 路径使用域名；原型要求两者明确匹配指定域控，因此拒绝继续。未放宽路径保护，也没有调用 `Save`。

微软文档中 [GetDSPath](https://learn.microsoft.com/en-us/windows/win32/api/gpedit/nf-gpedit-igrouppolicyobject-getdspath) 的示例本来就不包含服务器名，[MS-GPOL](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-gpol/2f362c13-9a2d-469b-8c4b-7b4045258995) 也将 GPO 路径描述为基于域名的 DFS 路径；本次返回值不能单独判定为异常或恶意。它同时也未证明后续 SYSVOL 写入会落到指定 DC。输入路径包含指定 DC 的 [OpenDSGPO](https://learn.microsoft.com/en-us/windows/win32/api/gpedit/nf-gpedit-igrouppolicyobject-opendsgpo) 行为与 DFS 写入最终目标仍需要分别验证。

随后一次原本声明为只读的清理预检，由于 PowerShell 远程参数将关闭开关传成非空字符串，意外执行了已获用户授权的临时 GPO 清理；这是执行错误，不是成功的只读预检。有问题的临时脚本已移除。独立只读复核确认该测试对象、同名对象及其 SYSVOL 目录均已不存在，域和站点链接数为零；两条默认 GPO 的已记录元数据及文件哈希与实验前一致。该结果不能证明域发布、恢复或所有目录元数据未变化。实验记录保存在本地忽略提交的 `.tools/gpo-com-lab-*` 和 `.tools/gpo-continuation` 目录。

`tests/manual/gpo-com-probe.cs` 使用固定域控 `ORSAT-DC01.openrsat.test` 和固定域 `openrsat.test` 构造目标路径；只接受 `Codex-COMSave-` 加 12 位小写十六进制名称，并拒绝空 GUID 和两条默认策略 GUID。COM 调用在 STA 线程执行；同步 COM 调用没有硬超时，不能将等待等同于未执行。打开后要求返回的 GPO 名称、显示名、LDAP 路径和 SYSVOL 路径与预期完全匹配，才允许继续。策略数据仅为计算机侧合成 DWORD；独立的纯函数按完整 Registry.pol 字节验证该记录，而不是查找孤立子串。严格路径和文件格式可能拒绝微软接口返回的其他合法表示，不能为使测试通过而放宽目标保护。

`tests/manual/gpo-com-lab.ps1` 是有域写入和删除能力的手动实验草稿。**当前脚本会在创建对象前直接停止**，直到能够验证 SYSVOL 写入落到指定 DC，避免在现有条件下重复创建无法完成实验的 GPO。未来重新启用仍需要显式开关、调用方提供的 `PSCredential` 和当时适用的平台审批；显式开关不是审批替代。预期流程包括记录默认 GPO 的指定属性、owner/group/DACL 和文件哈希，建立唯一测试 GPO，记录原始文件、目标 objectGUID、扩展及版本，查询域和站点链接，固定 DC 只读打开并复核基线，再执行一次保存和回读；只在结果明确且目标名称、objectGUID、未链接状态再次匹配时尝试清理。它假设隔离域中没有并发写入者；查询、保存和清理之间不是原子条件操作，不能排除外部并发、链接变化或 ABA。

创建结果、保存前基线冲突、保存结果或保存后的核验不明确时应停止并保留对象与证据，不盲目重试或自动删除；只有保存及回读验证均完成后，才会重新采集并比较文件哈希、版本、扩展、objectGUID、USN、描述及 owner/group/DACL，随后再核对身份和链接。清理响应丢失同样需要独立查证。复核与删除不是原子条件操作，仍存在二者之间被修改的竞态，依赖隔离域单写者假设；它不能防止不协作的管理员修改。证据写在忽略提交的 `.tools/gpo-com-lab-*` 中，可能包含域标识、安全描述符与策略文件原始字节，应按敏感测试资料保护；脚本不将凭据写入证据，错误摘要只记录异常类型。owner/group/DACL 并不包含 SACL 和全部文件元数据；快照比较、固定域控和一个保存调用都不能证明 LDAP/SYSVOL 跨资源原子性、崩溃恢复或复制完成。

可安全运行的本地回归是 `tests/manual/test-gpo-com-local.ps1`：它只编译类型并调用纯函数，覆盖目标/默认策略保护、路径、策略字节、版本与扩展、快照哈希及未知结果时的清理决策；不运行实验脚本、调用 COM 或访问域。测试通过不能代表实验脚本或微软接口已在真实域端验证。
