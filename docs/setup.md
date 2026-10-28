# 部署步骤

## 1. 准备软件

1. 安装 PowerShell 7.4 或更高版本。
2. 安装 Docker Desktop。
3. 将 Docker Desktop 切换为 Linux 容器。
4. 从[官方发行目录](https://download.nextcloud.com/desktop/releases/Windows/)安装 Nextcloud Desktop 35.0.0 x64。
5. 暂时退出桌面客户端。

官方安装包提供运行库和 Windows 系统集成。
初始化后，工具安装本项目的固定客户端覆盖包。

## 2. 配置目录

1. 将 `.env.example` 复制为 `.env`。
2. 将 `DATA_DIR` 设为新的运行目录。
3. 将 `LIBRARY_DIR` 设为新的文件库目录。
4. 将 `NEXTCLOUD_CLIENT` 设为客户端程序路径。
5. 检查三个端口是否可用。

目录使用正斜线。例如：`D:/BaiduLibraryData`。
使用仓库之外的两个独立目录树，分别保存运行数据和文件库。
运行目录使用支持 NTFS 权限的本机磁盘。首次初始化使用空目录。

## 3. 初始化

在仓库根目录执行：

```powershell
pwsh -File .\windows\Library.ps1 -Action Init
pwsh -File .\windows\Library.ps1 -Action PrepareClient
pwsh -File .\windows\Library.ps1 -Action Prepare
pwsh -File .\windows\Library.ps1 -Action StartServer
```

预期结果：输出中的 `server_running` 为 `true`。
`Init` 创建运行目录和随机凭据。再次执行时保留已登记实例的凭据和状态。
`PrepareClient` 下载固定覆盖包，同时更新主程序、核心库和虚拟文件插件。
Windows 管理员确认只用于覆盖程序文件。客户端以当前普通用户权限启动。
安装过程在运行目录中备份原程序文件。
`Prepare` 需要网络。日常启动使用本地镜像。

## 4. 配置 OpenList

1. 打开 `OPENLIST_PORT` 对应的本机地址。
2. 按[官方说明](https://doc.oplist.org/)设置管理员账号。
3. 添加百度网盘存储。
4. 按[百度驱动说明](https://doc.oplist.org/guide/drivers/baidu)完成百度授权。
5. 将存储挂载路径设为 `/baidu`。
6. 为文件库选择独立的百度物理目录。
7. 将该存储的 WebDAV 策略设为本地代理。
8. 创建名称与 `OPENLIST_USER` 相同的 WebDAV 用户。
9. 按目标目录授予该用户所需的读写权限。
10. 确认该用户可以访问 `OPENLIST_DAV_PATH`。

默认 `/dav/baidu` 对应根目录用户看到的 `/baidu` 存储。
如果用户基础目录已设为 `/baidu`，将 WebDAV 路径设为 `/dav`。
同时将 `METADATA_DAV_PATH` 设为共享文件库在该用户下的路径。
各设备选择相同的百度物理目录。

## 5. 连接共享元数据

适配器在百度目录的 `.baidulibrary` 中保存快照和操作记录。

如果这是第一台设备，先发布登记：

```powershell
pwsh -File .\windows\Library.ps1 -Action PublishMetadata
```

输入专用 WebDAV 用户的密码。工具保存受 Windows 保护的本机凭据。
首份发布由一台设备完成。
如果已有设备发布了元数据，新设备直接执行下一步。

## 6. 完成文件库配置

```powershell
pwsh -File .\windows\Library.ps1 -Action ConfigureStorage
pwsh -File .\windows\Library.ps1 -Action Build
pwsh -File .\windows\Library.ps1 -Action Pair
pwsh -File .\windows\Library.ps1 -Action EnableStartup
pwsh -File .\windows\Library.ps1 -Action CreateShortcut
```

`ConfigureStorage` 校验 WebDAV 凭据，读取共享状态，并创建专用外部存储。
已有匹配的外部存储会被保留。

`Pair` 使用[上游配对接口](https://docs.nextcloud.com/server/stable/admin_manual/desktop/massdeployment.html#non-interactive-account-provisioning)配置本地账号，并启用 Windows 虚拟文件。
配对凭据在进程启动参数中短暂出现。请在自己控制的 Windows 账号下操作。
配对完成后，专用配置和 Windows 凭据保护机制负责保存凭据。

首次配对使用新的空文件库目录。
专用配置已有本地账号时，`Pair` 按现有配置启动。
已有文件库的暂停状态继续生效。

前置软件、OpenList 和首份元数据准备完成后，也可执行：

```powershell
pwsh -File .\windows\Library.ps1 -Action Setup
```

`Setup` 准备镜像和补丁客户端、配置外部存储、完成配对，并登记自启。
单独执行 `Pair` 时，也会检查并准备同一客户端版本。
控制窗口、桌面快捷方式和 Windows 自启使用同一个入口。

## 7. 验证启动

```powershell
pwsh -File .\windows\Library.ps1 -Action Start
pwsh -File .\windows\Library.ps1 -Action Status
```

预期结果：`client_prepared`、`server_running`、`client_running`、`profile_ready`、`file_accessible` 和 `ready` 均为 `true`。

1. 在第一台设备创建一个空文件和一个普通文件。
2. 等待客户端完成同步。
3. 在第二台设备执行 `RefreshMetadata`。
4. 等待第二台设备完成目录发现。
5. 确认空文件大小为零。
6. 打开普通文件并确认内容。
7. 通过不同文件上的操作验收双向同步。

同一文件发生并发修改时，按客户端的冲突提示处理。
一致性边界见[多设备元数据](multi-device.md)。

补丁客户端让忽略项保持静默，并使用单一来源显示创建活动。
客户端发布包和源码见[客户端补丁](client.md)。

## 8. 配置备用下载

默认使用 OpenList 下载。备用 PCS 下载采用独立会话凭据。
配置方法见[备用下载](downloads.md)。
