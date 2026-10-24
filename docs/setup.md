# 部署步骤

## 1. 准备软件

1. 安装 PowerShell 7.4 或更高版本。
2. 安装 Docker Desktop。
3. 将 Docker Desktop 切换为 Linux 容器。
4. 从 [Nextcloud 官方站点](https://nextcloud.com/install/#install-clients)安装桌面客户端。
5. 暂时退出桌面客户端。

本项目不分发或自动安装第三方客户端。

## 2. 配置目录

1. 将 `.env.example` 复制为 `.env`。
2. 将 `DATA_DIR` 设为新的运行目录。
3. 将 `LIBRARY_DIR` 设为新的文件库目录。
4. 将 `NEXTCLOUD_CLIENT` 设为客户端程序路径。
5. 检查三个端口是否可用。

目录使用正斜线。例如：`D:/BaiduLibraryData`。

运行目录与文件库必须位于仓库之外。它们不能互相包含。

运行目录必须使用支持 NTFS 权限的本机磁盘。初始化只允许空目录。

## 3. 初始化

在仓库根目录执行：

```powershell
pwsh -File .\windows\Library.ps1 -Action Init
pwsh -File .\windows\Library.ps1 -Action Prepare
pwsh -File .\windows\Library.ps1 -Action StartServer
```

预期结果：输出中的 `server_running` 为 `true`。

`Init` 创建运行目录和随机凭据。再次执行时，它不会重置已登记的实例。

`Prepare` 需要网络。后续日常启动只使用本地镜像。

## 4. 配置 OpenList

1. 打开 `.env` 中 `OPENLIST_PORT` 对应的本机地址。
2. 按 [OpenList 官方说明](https://doc.oplist.org/)设置管理员账号。
3. 添加百度网盘存储。
4. 按[百度驱动说明](https://doc.oplist.org/guide/drivers/baidu)完成百度授权。
5. 将存储挂载路径设为 `/baidu`。
6. 为文件库选择独立的百度目录。
7. 创建名称与 `OPENLIST_USER` 相同的 WebDAV 用户。
8. 只授予该用户目标目录所需的读写权限。
9. 确认该用户可以访问 `/baidu`。

将该存储的 WebDAV 策略设为本地代理。该模式由 OpenList 转发下载内容。见[上游策略说明](https://doc.oplist.org/guide/drivers/common)。

百度大文件下载对请求头有要求。首次验收应包含一个大于 20 MiB 的文件。不要只检查小文件。

授权仅在此步骤执行。不要把令牌或密码写入仓库。

## 5. 配置 Nextcloud 外部存储

1. 打开 `.env` 中 `SERVER_PORT` 对应的本机地址。
2. 使用 `NEXTCLOUD_USER` 登录。
3. 从运行目录的 `secrets/nextcloud-admin-password.txt` 读取初始密码。
4. 在应用管理中启用“External storage support”。
5. 在管理设置中打开“外部存储”。
6. 添加 WebDAV 存储。
7. 按下表填写字段。

| 字段 | 值 |
| --- | --- |
| 文件夹名称 | `Baidu`；与 `CLIENT_REMOTE_PATH=/Baidu` 一致 |
| 主机 | `empty-codec:8080` |
| 远端路径 | `dav/baidu` |
| 安全连接 | 关闭；此连接只位于本机 Docker 网络中 |
| 认证方式 | 用户名和密码 |
| 用户名 | `OPENLIST_USER` |
| 密码 | 上一步创建的 OpenList WebDAV 密码 |
| 可用账号 | `NEXTCLOUD_USER` |

8. 等待存储状态变为可用。
9. 打开文件列表中的 `Baidu` 文件夹。
10. 确认目标目录内容可见。

适配器地址必须使用 `empty-codec` 服务名。不要在容器内使用 Windows 的 `127.0.0.1`。

## 6. 配对桌面客户端

执行：

```powershell
pwsh -File .\windows\Library.ps1 -Action Pair
```

这是显式配对操作。它会打开客户端界面。

1. 将服务器地址设为本地入口。例如：`http://127.0.0.1:8787`。
2. 使用本地 Nextcloud 账号完成授权。
3. 将远端目录设为 `CLIENT_REMOTE_PATH`。
4. 将本地目录设为 `LIBRARY_DIR`。
5. 启用虚拟文件功能。
6. 关闭客户端自身的“登录后自动启动”选项。

首次配对必须使用空文件库目录。工具不会自动合并旧目录。

如果客户端已经保存了本地账号，`Pair` 不会清除该账号。

## 7. 验证启动

```powershell
pwsh -File .\windows\Library.ps1 -Action Start
pwsh -File .\windows\Library.ps1 -Action Status
```

预期结果：`server_running`、`client_running` 和 `profile_ready` 均为 `true`。

1. 在文件库中打开一个已有的小文件。
2. 确认内容正确。
3. 检查客户端是否报告同步错误。

这一步需要部署者自行验收。静态检查不能替代此步骤。

## 8. 登记自启

```powershell
pwsh -File .\windows\Library.ps1 -Action EnableStartup
pwsh -File .\windows\Library.ps1 -Action CreateShortcut
```

启动项和快捷方式都调用相同的本地链路。它们不会调用配对操作。
