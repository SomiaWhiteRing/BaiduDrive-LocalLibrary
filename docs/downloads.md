# 备用下载

默认下载链路是 Nextcloud → 适配器 → OpenList → 百度。

读取较大文件遇到 403、408、429 或服务器错误时，适配器可以使用 BaiduPCS-Go 4.0.1 获取 HTTPS 直链。
备用链路每次最多预取 16 个分片，全局最多同时执行 24 个数据请求。
每个分片按范围、总长度和实际字节数检查。
响应中断时，客户端会收到不完整响应并按其规则重试。

## 准备程序

```powershell
pwsh -File .\windows\Library.ps1 -Action PrepareDownloads
```

该操作从[上游固定发行版](https://github.com/qjfoidnh/BaiduPCS-Go/releases/tag/v4.0.1)下载 Linux amd64 程序。
程序保存在运行目录的 `tools/BaiduPCS-Go`。
镜像和仓库保存自有源代码。

## 保存授权

BaiduPCS-Go 使用自己的百度登录会话。
按[上游登录说明](https://github.com/qjfoidnh/BaiduPCS-Go)在运行目录的 `empty-codec/pcs` 中建立 `pcs_config.json`。
将配置中的账号设为 OpenList 使用的同一个百度账号。
启用 HTTPS，并使用直连配置。

在同一目录创建 `download.json`：

```json
{
  "account_uid": "自己的百度 UID",
  "remote_root": "/自己的百度物理目录",
  "dav_prefix": "/dav/baidu"
}
```

`remote_root` 与 `dav_prefix` 必须表示相同的目录。
会话、UID 和真实路径由部署者保存在私人运行目录中。
配置完成后，重新创建适配器容器，使启动时读取新配置。

## 下载策略

| `PCS_DOWNLOAD_MODE` | 行为 |
| --- | --- |
| `fallback` | 优先 OpenList，失败时尝试 PCS |
| `prefer` | 对符合条件的读取优先尝试 PCS |
| `0` | 使用 OpenList |

默认值为 `fallback`。
已有测量中，OpenList 在部分文件上更快。
部署者按自己的文件和网络验收下载速度。
