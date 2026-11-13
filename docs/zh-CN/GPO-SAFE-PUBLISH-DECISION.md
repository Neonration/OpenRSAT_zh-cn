# GPO 发布方式评估

结论：**当前不应开启自动域发布。** 现有代码能离线准备和只读复核，尚不能保证以已审阅的目标身份和版本为条件发布，也没有可信、可恢复的跨资源事务。建议先保留本地导出和清晰的变更说明，由管理员在维护窗口使用 GPMC 检查并执行对应的策略变更，完成后验证所选域控与复制状态。这是人工协作流程，并非自动事务；当前导出的是原始 Registry.pol，不能直接当作 `Import-GPO` 所需的 GPO 备份包。微软的 [Import-GPO](https://learn.microsoft.com/en-us/powershell/module/grouppolicy/import-gpo?view=windowsserver2022-ps) 接受 GPO 备份，并将其设置导入目标 GPO；不能仅凭文件扩展名推断兼容。

## 平台证据

| 能力 | 已知边界 |
|---|---|
| 路径替换 | [ReplaceFileW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew) 可接收备份名，尝试保留 DACL 等属性；不同错误可能留下不同的原文件、候选和备份名称及属性状态。忽略 ACL 或合并错误的标志不能用于保证 ACL；`REPLACEFILE_WRITE_THROUGH` 文档称不支持。不能把一次成功扩大为崩溃安全或所有元数据保全。 |
| 目标条件 | [FILE_RENAME_INFORMATION](https://learn.microsoft.com/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information) 支持目标存在时替换或拒绝，但其参数不包含要替换目标的预期文件 ID、版本或内容；不能据此称为目标身份 CAS。路径检查后目标可能变化；即使检查值再次相同也可能发生 ABA。 |
| SMB | [SMB2 FileRenameInformation](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-fscc/52aa0b70-8094-4971-862d-79793f41e6a8) 的 `ReplaceIfExists` 描述同名目标处理，网络操作的 RootDirectory 为零；并不提供上述预期身份条件。本轮没有在 SMB 服务端测试替换、断线或服务器实现差异，不能把本地结果外推。 |
| 共享和租约 | 文件共享模式会影响其他打开请求；[SMB oplock break](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/2a09fc40-1615-42df-bda6-2865b8d6da95) 是具体的中断/通知过程，不能替代覆盖所有管理员和资源的事务锁。已有映射具有独立生命周期，见下方实验。 |
| 持久性与多资源 | Registry.pol、GPT.INI 和 LDAP 更新不是一个共同原子提交；进程崩溃、失联、服务器重启和复制可能造成部分完成或结果未知。现有 CRC、只读匹配和临时备份不能证明可信、新鲜或掉电持久。 |

## 本地专用文件实验（2026-11-12）

在 Windows 10.0.26200、本机 C: NTFS 的独立随机临时目录运行 [gpo-replace-probe.ps1](../../tests/manual/gpo-replace-probe.ps1)，只使用合成字节；实验完成后删除测试文件和空目录，没有访问域或修改 ACL。

1. `ReplaceFileW` 带备份成功：目标由 `01-02-03` 变为 `04-05-06`，备份为 `01-02-03`，此次调用前后 owner/DACL 描述符字节相同。
2. 保持原文件不共享打开时，替换失败并返回错误 32；原文件字节及 owner/DACL 未变，候选仍存在，未产生备份。
3. 先建立可写映射并关闭原文件流，再尝试独占打开：本机未能取得独占打开；随后替换成功。替换后通过原映射写入 `2A`，最终目标为 `07-08-09`，备份由原 `04-05-06` 变成 `2A-05-06`。这说明此次实验中，替换成功不意味着旧对象或备份不会被先前映射继续修改。
4. 顺序模拟检查后变更：先读到 `01-02-03`，再将目标改为 `63-02-03`，随后调用替换；调用成功，目标成为 `04-05-06`，备份为 `63-02-03`。这是无并发时演示 API 不验证先前读取的值，不能用来推导所有竞争时序。

这些是单机、单次的实际观察；不是 NTFS/Windows 的完整形式化保证，也不验证映射竞态的所有时序、其他文件系统、SMB、崩溃、掉电、ACL 的所有字段或 GPMC 互操作。脚本单独运行，不加入产品执行流程。

## 可选产品方向

1. **当前建议：人工执行。** 保留目标绑定只读草稿、导出和差异，管理员通过 GPMC 明确编辑、备份和复核。人工窗口可降低协作冲突，但不能阻止未参与者写入，也不保证 LDAP/SYSVOL 原子性或自动回滚。需要另行验证 GPMC 能表达具体原始 Registry.pol 项；不能把原始导出包装成可直接导入的备份。
2. **协作维护窗口。** 管理员停止其他管理操作，应用前后在固定 DC 检查身份、版本、内容和权限，持有独立可信备份与审计记录；采用分步发布、未知状态停机和人工查证。前提是所有写入者自愿遵守；不遵守、映射、ABA、断线与复制仍可能破坏假设，且当前没有实现可发布的后端。
3. **受控写入服务。** 建立单一写入者并在组织层面限制其他写入入口，管理可信备份、身份、操作日志、条件验证和恢复。需要实际部署、权限模型和故障验证；ACL/服务配置可能影响其他工具，必须单独审批。服务只能控制其信任边界内的写入，不能自动获得跨 LDAP/SMB 的原子性，管理员、已有映射和外部绕过仍须处理。

任何自动发布方案上线前至少需要：经验证的目标身份和条件发布机制、受保护且防回滚的独立备份/日志、原 ACL 与其他元数据处理、已存在映射和非协作者的策略、固定 DC 的未知结果查证、崩溃/网络故障注入及复制检查。若平台无法提供所需条件，应明确采用经用户认可的协作风险模型；不能用 CRC、`rrVerified` 或一次本地替换成功代替这些条件。

## 官方恢复接口的适用范围

[GPMC 备份与恢复接口](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/gpmc/gpo-operations-supported-by-the-gpmc)是后续实现恢复的候选：备份包含策略、标识和 ACL；恢复回原域并恢复策略与 ACL，但不修改域、站点或 OU 上的 GPO 链接。导入只覆盖目标策略设置，不恢复目标 ACL 或链接。两者都可能覆盖现有更改，不能混作只恢复单条 Registry.pol 的操作。

[IGPM::GetDomain](https://learn.microsoft.com/en-us/windows/win32/api/gpmgmt/nf-gpmgmt-igpm-getdomain) 支持指定域控；[Restore-GPO](https://learn.microsoft.com/en-us/powershell/module/grouppolicy/restore-gpo?view=windowsserver2025-ps) 也提供 `-Server` 和用于选择具体备份的 `-BackupId`。这些接口提供了目标选择和备份语义，并不证明本项目已实现恢复、各底层文件操作的实际服务器、并发条件、结果未知后的处理或复制完成。原始离线草稿不是 GPMC 备份，不能直接用于上述恢复。
