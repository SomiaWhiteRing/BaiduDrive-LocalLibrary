# 配置说明

配置文件是仓库根目录的 `.env`。Git 忽略规则将该文件留在本地。

配置值使用单行文本。目录可以使用引号。工具按文本读取配置值。

## 字段

| 字段 | 用途 | 示例 |
| --- | --- | --- |
| `COMPOSE_PROJECT_NAME` | Docker 实例和启动项名称 | `baidudrive-local` |
| `DATA_DIR` | 运行目录 | `D:/BaiduLibraryData` |
| `LIBRARY_DIR` | Windows 文件库目录 | `D:/BaiduLibrary` |
| `NEXTCLOUD_CLIENT` | 客户端程序 | `C:/Program Files/Nextcloud/nextcloud.exe` |
| `NEXTCLOUD_USER` | 本地 Nextcloud 账号 | `library` |
| `OPENLIST_USER` | 适配器专用 WebDAV 用户 | `library-storage` |
| `CLIENT_REMOTE_PATH` | 本地账号下的外部存储路径 | `/Baidu` |
| `SERVER_PORT` | 本地入口端口 | `8787` |
| `OPENLIST_PORT` | OpenList 管理端口 | `5244` |
| `CODEC_PORT` | 适配器诊断端口 | `5246` |
| `TZ` | 容器时区 | `UTC` |
| `OPENLIST_DAV_PATH` | Nextcloud 外部存储的 WebDAV 根目录 | `/dav/baidu` |
| `METADATA_DAV_PATH` | 共享文件库在 WebDAV 中的目录 | `/dav/baidu` |
| `SHARED_METADATA` | 共享逻辑元数据；1 为启用 | `1` |
| `CLIENT_MAX_PARALLEL` | 客户端发现任务共享预算，1 至 64 | `24` |
| `PCS_DOWNLOAD_MODE` | 备用下载策略 | `fallback` |

三个服务分别使用独立端口。端口范围是 1024 至 65535。

相对目录按仓库根目录解析。建议使用固定的绝对目录。

实例初始化后，保持项目名、运行目录、账号名和本地入口端口与实例记录一致。为另一套配置创建独立实例。

## 网络

| 组件 | 连接的网络 | 网络用途 |
| --- | --- | --- |
| Nextcloud | 内部网络 | 本地文件接口 |
| 后台任务 | 内部网络 | 定期后台任务 |
| MariaDB、Redis | 内部网络 | 元数据、锁和缓存 |
| 本地入口 | 默认网络、内部网络 | 本机 HTTP 转发 |
| 适配器 | 默认网络、内部网络 | 用于读取上游重定向内容 |
| OpenList | 默认网络 | 用于访问百度 |

本地入口负责 HTTP 反向代理。Nextcloud 服务管理应用代码和用户数据。

Docker 内部网络用于限制服务器出站。[规则依据](https://docs.docker.com/reference/compose-file/networks/)。

## 静默设置

服务器关闭以下功能：

- 官方更新检查。
- 应用商店。
- 官方公告和调查组件。
- 官方目录查询。
- 外网连通性探测。
- 在线帮助入口。

应用商店和目录连接组件可能是上游必需组件。工具通过配置关闭其官方联网功能。

客户端使用 `skipUpdateCheck=true`。这是[上游支持的设置](https://docs.nextcloud.com/server/stable/user_manual/en/desktop/autoupdate.html)。

工具保留真正的同步故障提示。整机防火墙和客户端公网访问策略由部署者维护。

## 文件名和修改时间

本地 Nextcloud 配置允许归档 `.htaccess` 等源文件。该配置用于本机文件库。

`ApplyPolicy` 保留专用的 `node_modules` 目录排除规则。
该操作允许名称以 `~` 结尾的文件和已有 `.crdownload` 文件。
安装目录的全局规则需要对应文件的写入权限。工具按需请求 Windows 管理员确认，仅授予当前用户该文件的修改权限。

适配器将逻辑修改时间保存在状态目录中。备份和恢复时，完整保留该目录。

## 上传空间

适配器的单次上传上限是 32 GiB。

适配器先完整暂存内容，再转发上传。为适配器预留的空间，至少应等于所有并发上传文件的总大小。

Nextcloud 自身的临时空间另计。部署者根据并发上传量安排磁盘容量。

## 资源配置

默认资源配置与当前参考部署一致：

| 组件 | CPU 上限 | 内存上限 | 请求设置 |
| --- | --- | --- | --- |
| Nextcloud | 6 | 4 GiB | 24 个后端请求 |
| 本地入口 | 1 | 512 MiB | event 模型，64 个请求 |
| 适配器 | 4 | 1 GiB | 24 个数据请求 |
| MariaDB | 2 | 1.5 GiB | 512 MiB 缓冲池 |

这些值是上限。小型设备可在 `compose.yaml` 中降低配置。

`STARTUP_NAME` 可指定现有 HKCU 启动项名称。
省略时使用 `BaiduDriveLocal-<项目名>`。

旧 `.env` 可继续使用。新增字段采用默认值。
自定义 WebDAV 根目录时，同时检查共享目录。
Windows 客户端继续采用 `NORMAL` SQLite 锁模式，供本机只读诊断使用。
