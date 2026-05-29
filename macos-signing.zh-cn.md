# macOS 首次运行和签名脚本说明

本仓库提供的 macOS arm64 包是内部测试/自用包，不是 Apple Developer ID 公证包。因此在其他 Mac 上第一次打开时，系统可能会提示：

```text
Apple 无法验证 “OpenRSAT” 是否包含恶意软件
```

这是 Gatekeeper 对未公证应用的拦截，不代表应用一定损坏。

## 需要运行的脚本

发布包内包含：

```text
OpenRSAT.app
fix-and-open.command
```

首次在其他 Mac 上使用时，保持这两个文件在同一个目录，然后运行：

```bash
./fix-and-open.command
```

也可以在 Finder 中双击 `fix-and-open.command`。

## 脚本做了什么

`fix-and-open.command` 会执行以下步骤：

1. 检查同目录下是否存在 `OpenRSAT.app`。
2. 移除 macOS 下载隔离属性：

    ```bash
    xattr -dr com.apple.quarantine OpenRSAT.app
    ```

3. 对应用执行本机 ad-hoc 签名：

    ```bash
    codesign --force --deep --sign - OpenRSAT.app
    ```

4. 校验签名：

    ```bash
    codesign --verify --deep --verbose=2 OpenRSAT.app
    ```

5. 打开应用。

## 如果脚本无法运行

如果双击脚本没有反应，或提示没有权限，打开终端进入解压目录后执行：

```bash
chmod +x fix-and-open.command
./fix-and-open.command
```

如果 macOS 仍然拦截，到：

```text
系统设置 > 隐私与安全性
```

找到 OpenRSAT 的拦截提示，选择允许打开。

## 注意事项

- `fix-and-open.command` 只对当前这台 Mac 生效。
- 换到另一台 Mac 后，可能需要重新运行一次脚本。
- 该脚本不等同于 Apple 官方公证。
- 正式对外分发应使用 Apple Developer ID 签名并提交 notarization。
- 应用内置 OpenSSL 1.1 dylib，脚本不会安装系统级 OpenSSL。

