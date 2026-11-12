# GPO 只读策略查看（第一阶段）

本阶段在现有 GPO 属性窗口增加 `Policy settings (read-only)` 页。它不是 GPO 编辑器，也不是完整的 GPMC 或有效策略计算器。

## 使用

1. 连接域控时使用该域控的 FQDN，须与 LDAP RootDSE 的 dnsHostName 一致。当前阶段不自动信任 IP 或域别名与另一个主机名的对应关系。
2. 在 ADUC 中找到 groupPolicyContainer 对象并打开属性，进入只读策略页。启用显示 GPO 后，也可从链接 GPO 节点的属性入口打开。
3. 点击 `Load SYSVOL settings (read-only)`。打开页面本身不会访问 SYSVOL。
4. 查看 GPC（LDAP）与 GPT.INI（SYSVOL）版本，以及 Computer configuration / User configuration 的 Registry.pol 内容。版本高16位为用户，低16位为计算机。
5. 点击“只读基线检查”，可对当前 GPO 的两侧文件和 LDAP 证据进行独立会话采集及复核。这个入口只检查当前基线，不携带或检查本地离线草稿；匹配仍表示安全证据不完整，不能授权写入。

基线检查仅支持原连接配置为当前 Windows 身份的 Kerberos、没有显式用户名或密码、未启用 TLS 且对象 GUID 可用的情况；其他认证方式会显示不支持。后台独立连接强制 Kerberos 签名与加密，并核对绑定用户、域控、所选对象 GUID 和原会话。不会复制或保存凭据，也不并发使用原 LDAP 客户端。对象或会话变化、取消及关闭会丢弃结果；系统调用中的 LDAP/SMB 不能强制中断，超时或取消后可能仍需等待返回。此入口尚未经真实域端到端验证。

新页面不暂存或提交 LDAP 属性修改，没有保存策略、创建策略或删除策略操作。原有其他属性页和已有功能保持原样，不应把整个属性窗口理解成只读。

## 身份与失败处理

- GPC 元数据在显式加载时从当前绑定的 LDAP 会话重新读取，不采用尚未保存的属性编辑值。
- SYSVOL 固定指向已核对的当前域控，不跟随 gPCFileSysPath 中任意主机、其他共享、路径穿越或设备路径。
- SMB 使用当前 Windows 身份，不复用 LDAP 密码，不创建凭据映射，不提示保存密码。因此 LDAP 连接成功不保证该 Windows 身份能读 SYSVOL。
- 显示不存在、拒绝访问、损坏、不支持、超限和 I/O 错误；缺少 Registry.pol 不表示整个 GPO 没有设置，其他扩展仍可能有策略。
- 域、连接、绑定用户、对象等改变后，过时读结果会被丢弃。文件读取使用独立快照，不在关闭页面后回调已销毁控件。
- GPC/GPT 版本相同仅代表版本数相同，不是内容完整性或复制状态证明。

## 格式和边界

GPC 的 LDAP versionNumber 按有符号 Int32 十进制读取，再保留原始32位转换为版本号；GPT.INI 的 Version 单独按无符号 DWORD 读取。例如 LDAP 的 -2147483648 与 GPT.INI 的 2147483648 表示同一版本，用户版本为32768、计算机版本为0。越界或非法文本仍明确失败。

Registry.pol 使用 Microsoft MS-GPREG：`PReg` 标识、DWORD little-endian 版本1、UTF-16LE 名称和分隔符、二进制 DWORD 类型和长度。未知类型保留数值和原始字节，界面明确标注 Unknown；已知类型显示 REG_* 名称。当前仅展示原始十六进制预览，不解释 ADMX 策略含义，也不执行删除指令等记录。

限制：单文件16MiB、单值65535字节、65536条记录、名称32767个UTF-16 code units；格式/截断/超限不返回部分成功记录。界面每条最多预览128字节，并显示完整数据长度。文件 transport 仅支持 Windows；其他平台明确 Unsupported。

规范：https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-gpreg/5c092c22-bf6b-4e7f-b180-b20743d368f5

## 验证范围

### 路径保护和大列表

Windows 文件打开使用固定 DC 的原生 MUP 路径，并禁止客户端名称重解析。读取时逐层打开并持有目录保护句柄，拒绝写入/删除共享；唯一允许的重解析点是规范 SYSVOL 域根的 MOUNT_POINT，并同时保护其链接和解析后的根目录。Policies、GPO GUID、Machine/User 以及最终文件发现重解析点即失败，不回退到不安全的打开方式。共享冲突或平台不支持也明确失败。

这以已连接的可信 DC 和配置好的 SYSVOL 根为边界，不是对恶意 SMB 服务器的完整性保证。隔离来宾的独立测试目录已验证服务器端 junction 在进入前被拒绝，合法 SYSVOL 根 junction 仍可读；没有在真实策略目录中放入恶意链接，也没有证明跨服务器跳转或凭据泄漏。

计算机和用户列表各按200条分页，保留全部解析记录、精确总数、上一页/下一页和直接选页，不调用 ProcessMessages。真实 Windows 控件测试中，双栏各65536条的初次显示约235毫秒，末页可访问；这是当前测试机测量值，不是所有环境的延迟保证。

- 新核心测试：有效/空策略文件、全截断位置、长度和记录数上下限、未知类型、奇数字节 payload、多记录、UTF-16 surrogate、GPT.INI BOM/版本及安全路径。
- 新 GUI harness：只读控件、不产生属性修改、计算机/用户版本、版本不一致、错误清空旧记录、未知类型与错误显示。
- 隔离域真实只读检查：两条默认 GPO 的 GPT.INI 版本2/1读取解析，用户/计算机版本拆分正确，四个不存在的 Registry.pol 返回 Missing。23项检查通过，全部既有 SYSVOL 文件哈希与 GPC 元数据前后不变。

当前测试域没有 GPMC 生成的 Registry.pol 样本。本阶段没有为测试创建或修改域策略，因此真实非空 Registry.pol、低权限拒绝访问、不同域控/复制竞争和实际新界面联网点击仍须补验。新页面主要标题可翻译，诊断文案当前仍有英文。后续开发不能将这些缺口写成已通过。

## 后续开发说明

当前新增取消、30秒协作预算、跨页面两个任务上限和连接/绑定会话令牌。系统在途SMB调用仍可能超出预算，LDAP元数据查询仍在UI线程。离线编辑模型及未实现的写入恢复设计见 [GPO-OFFLINE-EDITING.md](./GPO-OFFLINE-EDITING.md)。域写入入口仍未接入。
