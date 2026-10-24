# 第三方组件

第三方程序、镜像和安装包由部署者从上游获取。本项目自有代码和说明采用 MIT 许可证。

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

`compose.yaml` 记录部署镜像的固定摘要。摘要直接引用上游发行物。

本项目由独立维护者开发。各上游维护者负责对应的第三方产品。
