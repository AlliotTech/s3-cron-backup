# s3-cron-backup

[![Container](https://github.com/AlliotTech/s3-cron-backup/actions/workflows/docker.yml/badge.svg)](https://github.com/AlliotTech/s3-cron-backup/actions/workflows/docker.yml)

一个小型 Docker 镜像：按 cron 调用独立备份脚本，然后把脚本生成的文件上传到
Amazon S3、Cloudflare R2 或其他 S3 兼容对象存储。

镜像附带 `vaultwarden-backup.sh`，用于创建 Vaultwarden SQLite 在线一致性快照并
打包完整数据目录。上传逻辑不关心备份内容，因此也可以挂载自己的备份脚本。

```text
cron -> backup.sh -> BACKUP_SCRIPT -> BACKUP_OUTPUT -> aws s3 cp
```

## 功能

- 五段式 cron 定时任务，也支持立即执行一次；
- 上传前执行独立的 `BACKUP_SCRIPT`；
- 使用 `flock` 防止同一容器内的任务重叠；
- 支持 S3 endpoint 和 Cloudflare R2；
- 内置 Vaultwarden SQLite `.backup` 快照脚本；
- 发布 `linux/amd64` 和 `linux/arm64` 镜像。

镜像地址：

```shell
docker pull ghcr.io/alliottech/s3-cron-backup:latest
```

## 快速开始：Vaultwarden 备份到 R2

下载 [compose.example.yml](compose.example.yml) 和 [.env.example](.env.example)，
把 `.env.example` 复制为 `.env`，填写专用 R2 凭据、Account ID 和私有 bucket 名称：

```shell
cp .env.example .env
docker compose -f compose.example.yml up -d
```

示例每天在 `Asia/Shanghai` 02:00 执行，Vaultwarden 数据目录只读挂载到
`/data`，临时快照和压缩包写入 `/work`。成功上传后，本地压缩包会自动删除。

对象名称类似：

```text
s3://private-backup-bucket/vaultwarden/vaultwarden-20260820T020000Z.tar.gz
```

## 环境变量

### 调度和上传

| 变量 | 必需 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `CRON_SCHEDULE` | cron 模式 | - | 五段式 cron，例如 `0 2 * * *` |
| `TZ` | 否 | `UTC` | cron 时区，例如 `Asia/Shanghai` |
| `BACKUP_NAME` | 是 | - | 归档文件名前缀 |
| `BACKUP_SCRIPT` | 否 | `/scripts/vaultwarden-backup.sh` | 上传前执行的脚本 |
| `WORK_DIR` | 否 | `/tmp/s3-cron-backup` | 锁文件和备份产物所在目录 |
| `S3_BUCKET_URL` | 是 | - | 目标路径，例如 `s3://bucket/prefix` |
| `S3_ENDPOINT` | 否 | AWS 默认 endpoint | R2 endpoint 或其他 S3 兼容 endpoint |
| `S3_STORAGE_CLASS` | 否 | `STANDARD` | AWS CLI 上传使用的 storage class |
| `AWS_ACCESS_KEY_ID` | 是 | - | S3/R2 Access Key ID |
| `AWS_SECRET_ACCESS_KEY` | 是 | - | S3/R2 Secret Access Key |
| `AWS_SESSION_TOKEN` | 否 | - | 使用临时 AWS 凭据时设置 |
| `AWS_DEFAULT_REGION` | 否 | R2 自动为 `auto` | AWS S3 region；R2 一般无需设置 |

### 内置 Vaultwarden 脚本

| 变量 | 必需 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `TARGET` | 否 | `/data` | Vaultwarden 数据目录 |
| `SQLITE_DB_PATH` | 否 | `db.sqlite3` | 相对 `TARGET` 的 SQLite 文件路径 |
| `TAR_EXCLUDES` | 否 | 空 | 用户明确希望排除的 GNU tar pattern，空格分隔 |
| `BACKUP_OUTPUT` | 内部变量 | - | `backup.sh` 提供给备份脚本的输出路径 |

`TAR_EXCLUDES` 默认是空的。`icon_cache`、附件、发送文件、RSA key 和其他
Vaultwarden 数据默认都会进入归档。

当前运行中的 `db.sqlite3`、`db.sqlite3-wal` 和 `db.sqlite3-shm` 会由脚本自动
排除，并在原路径放入通过 `PRAGMA quick_check` 的 SQLite 快照。无需把这些文件写进
`TAR_EXCLUDES`。只有在你明确不需要某些可再生数据时才设置额外排除，例如：

```yaml
TAR_EXCLUDES: "some-cache temporary-files"
```

## 单次执行

容器命令使用 `backup`，即可跳过 cron 立即执行一次：

```shell
docker run --rm \
  -e BACKUP_NAME=vaultwarden \
  -e S3_BUCKET_URL=s3://private-backup-bucket/vaultwarden \
  -e S3_ENDPOINT=https://ACCOUNT_ID.r2.cloudflarestorage.com \
  -e AWS_ACCESS_KEY_ID=REDACTED \
  -e AWS_SECRET_ACCESS_KEY=REDACTED \
  -v /srv/vaultwarden:/data:ro \
  -v s3-cron-backup-work:/work \
  -e WORK_DIR=/work \
  ghcr.io/alliottech/s3-cron-backup:latest backup
```

## 使用自定义备份脚本

自定义脚本只需要遵守下面的接口：

1. 从环境变量 `BACKUP_OUTPUT` 读取输出文件路径；
2. 在该路径创建一个非空文件；
3. 成功返回 0，失败返回非零。

例如：

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

tar -czf "$BACKUP_OUTPUT" -C /data .
```

只读挂载脚本并覆盖默认值：

```yaml
environment:
  BACKUP_SCRIPT: /scripts/my-backup.sh
volumes:
  - ./my-backup.sh:/scripts/my-backup.sh:ro
```

## 一致性说明

SQLite 数据库快照是一致的，也支持 WAL 模式下在线备份。但数据库与附件等普通文件
之间不是原子快照。如果必须保证整套数据处于完全相同的时间点，请短暂停止
Vaultwarden，或使用宿主机文件系统快照。

归档没有客户端加密。请使用专用私有 bucket、最小权限的读写凭据和合理的对象生命周期
规则。建议定期执行真实恢复演练。

## 恢复

先从对象存储下载归档，在隔离目录检查内容：

```shell
mkdir restored-data
tar -tzf vaultwarden-20260820T020000Z.tar.gz
tar -xzf vaultwarden-20260820T020000Z.tar.gz -C restored-data
sqlite3 restored-data/db.sqlite3 'PRAGMA integrity_check;'
```

只有 `integrity_check` 返回 `ok` 后，再停止 Vaultwarden、保留原数据目录、调整恢复目录
的属主和权限，并用恢复目录替换容器的 `/data`。启动后检查登录、附件和发送文件。

## 镜像发布

GitHub Actions 会执行 ShellCheck、Hadolint 和多架构构建：

- 推送到 `main`：发布 `latest`、`main` 和 commit SHA tag；
- 推送 `v1.2.3` tag：发布 `1.2.3`、`1.2`、`1` 和 SHA tag；
- Pull Request：只检查和构建，不推送镜像。

本地构建：

```shell
docker build -t s3-cron-backup:local .
```

## License

[MIT](LICENSE)
