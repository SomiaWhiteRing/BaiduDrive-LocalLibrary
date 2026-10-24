# 配置说明

配置文件是仓库根目录的 `.env`。该文件不纳入 Git。

配置值只支持单行文本。目录可以使用引号。工具不执行配置中的命令。

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

三个端口必须不同。端口范围是 1024 至 65535。

相对目录按仓库根目录解析。建议使用固定的绝对目录。

实例初始化后，不要直接修改项目名、运行目录、账号名或本地入口端口。工具会拒绝与实例记录不同的配置。

## 网络

| 组件 | 连接的网络 | 直接访问公网 |
| --- | --- | --- |
| Nextcloud | 内部网络 | 不允许 |
| 后台任务 | 内部网络 | 不允许 |
| MariaDB、Redis | 内部网络 | 不允许 |
| 本地入口 | 默认网络、内部网络 | 仅运行反向代理 |
| 适配器 | 默认网络、内部网络 | 用于读取上游重定向内容 |
| OpenList | 默认网络 | 用于访问百度 |

本地入口不挂载用户数据，也不运行 Nextcloud 应用代码。

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

工具保留真正的同步故障。它不启用整机防火墙，也不添加客户端公网阻断规则。

## 文件名和修改时间

本地 Nextcloud 配置允许归档 `.htaccess` 等源文件。该配置只用于本机文件库。

客户端的全局排除规则仍然适用。工具不自动修改安装目录中的规则。

适配器将逻辑修改时间保存在状态目录中。不要单独删除该状态。

## 上传空间

适配器的单次上传上限是 32 GiB。

适配器先完整暂存内容，再转发上传。为适配器预留的空间，至少应等于所有并发上传文件的总大小。

Nextcloud 自身的临时空间另计。工具不会自动扩容磁盘。
