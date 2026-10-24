# 第三方组件

本仓库不包含第三方程序、镜像或安装包。MIT 许可证只覆盖本项目自有代码和说明。

以下组件由部署者单独取得。其许可以上游对应版本的文件为准。

| 组件 | 参考版本 | 上游授权与源码 |
| --- | --- | --- |
| Nextcloud Server | 34.0.4；镜像按摘要固定 | [服务器源码与许可证](https://github.com/nextcloud/server) |
| Nextcloud Desktop | 参考部署为 35.0.0 | [客户端源码与许可证](https://github.com/nextcloud/desktop) |
| OpenList | v4.2.6；镜像按摘要固定 | [AGPL-3.0 许可](https://github.com/OpenListTeam/OpenList/blob/v4.2.6/LICENSE) |
| MariaDB | 11.4 系列；镜像按摘要固定 | [源码与许可证](https://github.com/MariaDB/server) |
| Redis | 7.4 系列；镜像按摘要固定 | [Redis 7.4 的 RSALv2 / SSPLv1 授权说明](https://redis.io/legal/licenses/) |
| Python | 3.13；基础镜像按摘要固定 | [PSF 授权说明](https://docs.python.org/3/license.html) |
| HTTPX | 0.28.1 | [源码与许可证](https://github.com/encode/httpx) |
| Apache、PHP 及镜像内依赖 | 随 Nextcloud 镜像提供 | 见对应镜像及上游源码 |

`compose.yaml` 记录部署镜像的固定摘要。摘要直接引用已有发行物，不是本项目计算的文件校验值。

本项目不属于 Nextcloud、OpenList 或百度的官方产品。
