# 客户端补丁

本项目在 `nextcloud/desktop/sync-display.patch` 中维护客户端改动。
补丁适用于 Nextcloud Desktop `v35.0.0`。
上游提交为 `ce977e31810bc9f2cdffc4828cc0a14bd0792110`。

## 安装发布包

先安装官方 Nextcloud Desktop 35.0.0 x64，并退出客户端。
在 `.env` 中填写 `NEXTCLOUD_CLIENT`，再执行：

```powershell
pwsh -File .\windows\Library.ps1 -Action Init
pwsh -File .\windows\Library.ps1 -Action PrepareClient
```

版本和下载地址固定在 `nextcloud/desktop/release.json`。
发布包只覆盖下文列出的五个文件。
官方安装包继续提供运行库和 Windows 系统集成。
完整对应源码与覆盖包在[同一发布页](https://github.com/SomiaWhiteRing/BaiduDrive-LocalLibrary/releases/tag/client-35.0.0-locallibrary-20261028.1)。

安装过程备份原文件，并保留安装日志。
缓存和备份位于 `DATA_DIR/tools/client`。
管理员进程只安装文件，客户端由普通用户入口启动。

`Setup` 和 `Pair` 会准备同一固定版本。
`Start` 只读取本机准备记录和版本，不下载更新。
`Status` 中的 `client_prepared` 表示固定版本已准备完成。

离线安装时，先从发布页取得覆盖包：

```powershell
pwsh -File .\windows\Prepare-Client.ps1 -ClientPath 'C:\Program Files\Nextcloud\nextcloud.exe' -CacheDirectory D:\BaiduLibraryData\tools\client -PackageFile D:\Downloads\nextcloud-35.0.0-locallibrary-20261028.1-win64-overlay.zip
```

## 行为

- `FileIgnored` 项目不再计入同步警告。
- 忽略项不再进入客户端的问题列表。
- 服务器启用 Activity 应用时，创建成功的活动使用服务器记录。
- 服务器未启用 Activity 应用时，保留本地创建活动。
- 服务器更新同一活动分组时，刷新已有记录。

创建活动随服务器活动列表刷新后显示。
此修改处理客户端本地记录与服务器记录的重复展示。
服务器中的独立创建事件继续分别显示。

## 应用补丁

先准备 Git 和上游客户端源码。
在本项目仓库根目录执行：

```powershell
git clone --depth 1 --branch v35.0.0 https://github.com/nextcloud/desktop.git D:\Source\nextcloud-desktop
pwsh -File .\windows\Patch-Client.ps1 -SourceDirectory D:\Source\nextcloud-desktop -Check
pwsh -File .\windows\Patch-Client.ps1 -SourceDirectory D:\Source\nextcloud-desktop
```

`-Check` 仅检查补丁状态。
再次应用已完成的补丁时，脚本直接返回。
版本不匹配或源码冲突时，脚本停止操作。

## 构建和使用

按[上游构建说明](https://github.com/nextcloud/desktop/tree/v35.0.0#build)准备 Windows 依赖并编译客户端。
使用 Qt 6.11.2，并设置 `MIRALL_VERSION_BUILD=20261028` 和 `MIRALL_VERSION_SUFFIX=-locallibrary`。
同时构建 `nextcloudsync_vfs_cfapi` 和 `nextcloudsync_vfs_suffix`。
替换现有安装时，使用同一次构建生成的以下文件：

- `nextcloud.exe`
- `nextcloudsync.dll`
- `nextcloud_csync.dll`
- `nextcloudsync_vfs_cfapi.dll`
- `nextcloudsync_vfs_suffix.dll`

客户端按完整版本号校验虚拟文件插件。
保留旧插件会导致文件库无法加载。
写入受保护的安装目录时，使用 Windows 管理员权限。

本项目的托管入口使用固定发布包。
先执行 `PrepareClient`，再执行 `StartClient`。

`windows/Build.ps1` 只构建本项目的控制程序。
`Install-Code.ps1` 会复制客户端补丁、许可和应用脚本。
补丁应用脚本只修改指定的源码目录。
已安装的官方客户端需要替换为补丁构建版本后生效。

## 许可证

客户端补丁保留所修改上游源码的 `GPL-2.0-or-later` 许可证。
完整条款见 `nextcloud/desktop/COPYING`。
补丁应用脚本采用本项目的 MIT 许可证。
