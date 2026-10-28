# 日常操作

下列命令在仓库根目录执行。

## 启动

```powershell
pwsh -File .\windows\Library.ps1 -Action Start
```

启动顺序：Docker Desktop、本地服务、本地账号校验、专用客户端。

账号、目录和端口通过校验后，工具启动专用客户端。校验发现差异时，启动停止并记录原因。

如果客户端已经运行，工具复用该进程。

工具保留客户端已有的暂停状态。同步任务由客户端管理。

## 查看状态

```powershell
pwsh -File .\windows\Library.ps1 -Action Status
```

`profile_ready` 表示专用配置通过校验。文件上传进度和同步结果以客户端的传输队列、活动记录为准。

## 停止

```powershell
pwsh -File .\windows\Library.ps1 -Action Stop
```

工具先请求客户端退出，再停止本项目容器。工具在等待客户端退出期间保留服务。

停止后，百度文件、运行目录和 Docker 数据卷保持原样。

## 管理自启

```powershell
pwsh -File .\windows\Library.ps1 -Action EnableStartup
pwsh -File .\windows\Library.ps1 -Action DisableStartup
```

工具按项目名管理对应的启动项。其他项目的启动项保持原样。

如果移动仓库目录，重新登记自启和快捷方式。

## 更新本地凭据

如果更改了本地账号密码，执行：

```powershell
pwsh -File .\windows\Library.ps1 -Action SaveCredential
```

输入本地 Nextcloud 密码或应用密码。

凭据使用 Windows DPAPI 保存，并绑定保存它的 Windows 账号和电脑。更换账号或电脑后，在目标账号下重新保存凭据。

本地凭据与客户端保存的授权分开。客户端授权失效时，先在客户端中修复本地账号授权。

## 更新百度授权

1. 打开本地 OpenList 管理页面。
2. 更新百度存储授权。
3. 确认存储可以列出文件。
4. 再启动文件库。

开机启动复用 OpenList 中保存的百度授权。

## 备份

1. 在客户端中等待传输完成。
2. 执行 `Stop`。
3. 备份整个运行目录。
4. 保存 `.env` 的独立副本。
5. 保存仓库版本号或提交号。

运行目录包含凭据。备份必须使用访问控制或加密保护。

服务停止后，将数据库、适配器状态和其他运行资料作为同一备份整体保存。

## 恢复

1. 停止本项目容器。
2. 恢复同一时间点的整个运行目录。
3. 恢复相同配置和镜像版本。
4. 执行 `StartServer`。
5. 检查外部存储。
6. 执行 `Start`。

如果更换 Windows 账号或电脑，重新保存本地凭据并检查客户端配对。

日常故障处理使用 `Stop` 保留数据卷。`docker compose down -v` 用于明确需要删除代码卷的清理操作。

## 升级

客户端版本由 `nextcloud/desktop/release.json` 固定。
更新仓库后，先退出客户端，再执行 `PrepareClient`。
该操作安装固定覆盖包，日常 `Start` 继续复用本机文件。
客户端覆盖包的备份位于 `DATA_DIR/tools/client`。

1. 完成备份。
2. 在独立运行目录中准备新版本。
3. 执行显式的 `Prepare`。
4. 验证普通文件、空文件、重命名和删除操作。
5. 验证虚拟文件下载。
6. 通过验证后，再切换生产实例。

修改上游镜像时，更新 `compose.yaml` 中的固定摘要。`Prepare` 按配置中的固定摘要准备镜像。

## 同步已安装代码

```powershell
pwsh -File .\windows\Install-Code.ps1 -Destination D:\BaiduLibraryData\tool -Check
pwsh -File .\windows\Install-Code.ps1 -Destination D:\BaiduLibraryData\tool
```

`-Check` 列出源代码差异。
安装操作在目标目录备份将被替换的源代码，再复制通用文件。
目标目录的 `.env`、凭据、客户端配置和数据库继续由该实例维护。
完成复制后，在目标目录执行 `Build`，准备适配器镜像，再执行 `Start`。
启动时会同步本地服务器配置和容量缓存扩展。
