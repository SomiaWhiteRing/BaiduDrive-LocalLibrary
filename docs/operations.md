# 日常操作

下列命令在仓库根目录执行。

## 启动

```powershell
pwsh -File .\windows\Library.ps1 -Action Start
```

启动顺序：Docker Desktop、本地服务、本地账号校验、专用客户端。

如果账号、目录或端口不符合配置，启动立即停止。工具不会自动打开登录网页。

如果客户端已经运行，工具复用该进程。

工具保留客户端已有的暂停状态。`Start` 不等同于强制恢复所有同步任务。

## 查看状态

```powershell
pwsh -File .\windows\Library.ps1 -Action Status
```

`profile_ready` 只表示专用配置符合要求。它不能证明所有文件均已上传。

请在客户端中确认传输队列和同步错误。

## 停止

```powershell
pwsh -File .\windows\Library.ps1 -Action Stop
```

工具先请求客户端退出，再停止本项目容器。客户端没有退出时，工具保留服务。

停止不会删除百度文件、运行目录或 Docker 数据卷。

## 管理自启

```powershell
pwsh -File .\windows\Library.ps1 -Action EnableStartup
pwsh -File .\windows\Library.ps1 -Action DisableStartup
```

启动项按项目名区分。工具不删除其他项目的启动项。

如果移动仓库目录，重新登记自启和快捷方式。

## 更新本地凭据

如果更改了本地账号密码，执行：

```powershell
pwsh -File .\windows\Library.ps1 -Action SaveCredential
```

输入本地密码或本地应用密码。不要输入百度密码。

凭据使用 Windows DPAPI 保存。复制到其他 Windows 账号或电脑后，凭据可能无法解密。请在目标账号下重新保存凭据。

本地凭据与客户端保存的授权分开。客户端授权失效时，先在客户端中修复本地账号授权。

## 更新百度授权

1. 打开本地 OpenList 管理页面。
2. 更新百度存储授权。
3. 确认存储可以列出文件。
4. 再启动文件库。

工具不会在开机时跳转到百度授权页面。

## 备份

1. 在客户端中等待传输完成。
2. 执行 `Stop`。
3. 备份整个运行目录。
4. 保存 `.env` 的独立副本。
5. 保存仓库版本号或提交号。

运行目录包含凭据。备份必须使用访问控制或加密保护。

不要在容器运行时只复制数据库文件。不要单独备份适配器的 SQLite 文件。

## 恢复

1. 停止本项目容器。
2. 恢复同一时间点的整个运行目录。
3. 恢复相同配置和镜像版本。
4. 执行 `StartServer`。
5. 检查外部存储。
6. 执行 `Start`。

如果更换 Windows 账号或电脑，重新保存本地凭据并检查客户端配对。

不要使用 `docker compose down -v` 处理故障。该命令会删除本项目的代码卷。

## 升级

1. 完成备份。
2. 在独立运行目录中准备新版本。
3. 执行显式的 `Prepare`。
4. 验证普通文件、空文件、重命名和删除操作。
5. 验证虚拟文件下载。
6. 通过验证后，再切换生产实例。

修改上游镜像时，更新 `compose.yaml` 中的固定摘要。`Prepare` 使用配置中的镜像，它不会自行选择最新版本。
