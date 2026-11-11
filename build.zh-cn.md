# OpenRSAT 中文版构建说明

本文档记录本仓库的中文维护版构建流程，重点覆盖 macOS arm64。英文上游说明见 [`build.md`](./build.md)。

## 依赖

需要准备：

- Git
- Lazarus
- Free Pascal Compiler/FPC
- mORMot2 static files
- 7Zip 或 `7zz`
- macOS arm64 构建时需要 Xcode Command Line Tools

推荐使用 fpcupdeluxe 安装 Lazarus 和 FPC：

- macOS Intel: <https://github.com/LongDirtyAnimAlf/fpcupdeluxe/releases/latest/download/fpcupdeluxe-x86_64-darwin-cocoa.zip>
- macOS arm64: <https://github.com/LongDirtyAnimAlf/fpcupdeluxe/releases/latest/download/fpcupdeluxe-aarch64-darwin-cocoa.zip>

旧版 macOS 包使用过的环境示例（本次尚未用此环境验证 0.4.594）：

- Lazarus: `/Users/zhaoyiqing/Applications/lazarus`
- FPC: `/Users/zhaoyiqing/.local/openrsat/fpc-root/usr/local/bin/fpc`
- Target: `aarch64-darwin`

## 克隆仓库

```bash
git clone https://github.com/Neonration/OpenRSAT_zh-cn.git
cd OpenRSAT_zh-cn
git submodule update --init
```

这里只初始化一级子模块，与 CI 的 `submodules: true` 一致。不要添加 `--recursive`：`pltis_djoin` 的嵌套子模块包含私有依赖，本项目构建不需要递归获取它们。如果从上游仓库构建，可替换为上游地址。

## 安装 mORMot2 statics

mORMot2 需要额外 static 文件。

1. 下载：

    <https://github.com/synopse/mORMot2/releases/latest/download/mormot2static.7z>

2. 解压：

    ```bash
    7zz x -y mormot2static.7z -ostatic
    ```

3. 将解压后的 `static` 目录放到：

    ```text
    submodules/mORMot2/static
    ```

## 注册 Lazarus 包

以下路径按本地仓库路径替换。示例中仓库位于 `/OpenRSAT`。

```bash
/lazarus/lazarus/lazbuild --add-package-link /OpenRSAT/submodules/mORMot2/packages/lazarus/mormot2.lpk
/lazarus/lazarus/lazbuild --add-package-link /OpenRSAT/submodules/pltis_utils/pltis_utils.lpk
/lazarus/lazarus/lazbuild --add-package-link /OpenRSAT/submodules/pltis_virtualtrees/virtualtreeview_package.lpk
/lazarus/lazarus/lazbuild --add-package-link /OpenRSAT/submodules/pltis_djoin/pack/pltis_djoin.lpk
/lazarus/lazarus/lazbuild --add-package-link /OpenRSAT/submodules/pltis_uicomponents/pack/pltis_uicomponents.lpk
/lazarus/lazarus/lazbuild --add-package-link /OpenRSAT/submodules/metadarkstyle/metadarkstyle.lpk
/lazarus/lazarus/lazbuild --add-package-link /OpenRSAT/submodules/metadarkstyle/metadarkstyledsgn.lpk
/lazarus/lazarus/lazbuild --add-package-link /OpenRSAT/packages/OpenRSATCore/OpenRSATCore.lpk
/lazarus/lazarus/lazbuild --add-package-link /OpenRSAT/packages/OpenRSATGUI/OpenRSATGUI.lpk
```

如果 `lazbuild` 报 `Broken dependency: OpenRSATGUI`，通常是依赖包没有注册完整，重点检查 `pltis_djoin`、`virtualtreeview_package`、`MetaDarkStyle`。

## 编译 macOS arm64

基础命令：

```bash
/lazarus/lazarus/lazbuild --build-mode=macosx-arm64 /OpenRSAT/sources/OpenRSAT.lpi
```

如果 Lazarus 配置中的 FPC 路径不正确，可以显式指定 Lazarus 目录和 FPC：

```bash
PATH=/path/to/fpc/bin:$PATH \
/path/to/lazarus/lazbuild \
  --lazarusdir=/path/to/lazarus \
  --compiler=/path/to/fpc/bin/fpc \
  --build-mode=macosx-arm64 \
  /OpenRSAT/sources/OpenRSAT.lpi
```

在较新的 macOS/Xcode 上，旧版 FPC/Lazarus Cocoa 目标可能在最终链接时报错：

```text
ld: malformed method list atom
Error while linking
```

这种情况使用 classic linker 参数：

```bash
PATH=/path/to/fpc/bin:$PATH \
/path/to/lazarus/lazbuild \
  --lazarusdir=/path/to/lazarus \
  --compiler=/path/to/fpc/bin/fpc \
  --build-mode=macosx-arm64 \
  --opt='-k-ld_classic' \
  /OpenRSAT/sources/OpenRSAT.lpi
```

成功后生成：

```text
bin/macosx-arm64/OpenRSAT
```

## 语言资源

语言文件沿用上游的外置 PO 机制。打包时保留 `languages/OpenRSAT.*.po` 的全部语言，并包含新增的 `OpenRSAT.zh.po`。Windows 解压目录示例：

```text
OpenRSAT.exe
locale/
  OpenRSAT.en.po
  OpenRSAT.fr.po
  OpenRSAT.el.po
  OpenRSAT.pl.po
  OpenRSAT.zh.po
```

简体中文是设置中的额外语言选项，不改写用户已保存的语言偏好。不要再合并或嵌入旧 `Translation.*.po` 文件。

Windows 编译后，在仓库根目录复制全部语言文件：

```powershell
New-Item -ItemType Directory -Force bin\win64\locale | Out-Null
Copy-Item languages\OpenRSAT.*.po bin\win64\locale\
```

## 打包 macOS app

仓库现有的 `dist/OpenRSAT-macos-arm64.zip` 是历史构建，未包含本次合并上游 0.4.594 后的增强。下面是重新构建和打包的步骤，本次未生成或验证新版 macOS 包。

本仓库的可分发包结构：

```text
dist/OpenRSAT-macos-arm64/
  OpenRSAT.app
  fix-and-open.command
```

`OpenRSAT.app` 内需要包含：

```text
OpenRSAT.app/Contents/MacOS/OpenRSAT
OpenRSAT.app/Contents/MacOS/lib/libssl.dylib
OpenRSAT.app/Contents/MacOS/lib/libssl.1.1.dylib
OpenRSAT.app/Contents/MacOS/lib/libcrypto.dylib
OpenRSAT.app/Contents/MacOS/lib/libcrypto.1.1.dylib
OpenRSAT.app/Contents/Resources/locale/OpenRSAT.*.po
```

打包步骤示例：

```bash
mkdir -p dist/OpenRSAT.app/Contents/MacOS/lib
mkdir -p dist/OpenRSAT.app/Contents/Resources/locale
cp bin/macosx-arm64/OpenRSAT dist/OpenRSAT.app/Contents/MacOS/OpenRSAT
cp bin/macosx-arm64/lib/*.dylib dist/OpenRSAT.app/Contents/MacOS/lib/
cp languages/OpenRSAT.*.po dist/OpenRSAT.app/Contents/Resources/locale/
chmod +x dist/OpenRSAT.app/Contents/MacOS/OpenRSAT
codesign --force --deep --sign - dist/OpenRSAT.app

mkdir -p dist/OpenRSAT-macos-arm64
ditto dist/OpenRSAT.app dist/OpenRSAT-macos-arm64/OpenRSAT.app
chmod +x dist/OpenRSAT-macos-arm64/fix-and-open.command

cd dist
ditto -c -k --sequesterRsrc --keepParent OpenRSAT-macos-arm64 OpenRSAT-macos-arm64.zip
unzip -t OpenRSAT-macos-arm64.zip
```

## 首次打开和 Gatekeeper

未公证的应用在其他 Mac 上可能出现：

```text
Apple 无法验证 “OpenRSAT” 是否包含恶意软件
```

发布包内的 `fix-and-open.command` 用于内部测试场景：

1. 移除 `com.apple.quarantine`。
2. 对 `OpenRSAT.app` 执行本机 ad-hoc 签名。
3. 执行 `codesign --verify`。
4. 打开应用。

如果仍被系统拦截，到“系统设置 > 隐私与安全性”中允许打开 OpenRSAT。

面向使用者的独立说明见 [`macos-signing.zh-cn.md`](./macos-signing.zh-cn.md)。

## 已知 macOS 问题

- OpenSSL 加载失败：确认 `Contents/MacOS/lib` 下存在 OpenSSL 1.1 dylib。
- TLS 证书链错误：这是运行时 LDAP TLS 信任链问题，需要导入或信任企业 CA，不是编译问题。
- 字体/列表显示异常：与 Lazarus Cocoa/Retina 缩放相关，需保持当前 macOS 分支的 VirtualTrees 和 TTisGrid 修正。
- `Broken dependency: OpenRSATGUI`：重新注册 Lazarus package links。
- `ld: malformed method list atom`：编译时增加 `--opt='-k-ld_classic'`。
