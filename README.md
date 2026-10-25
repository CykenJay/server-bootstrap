# Debian 13 服务器初始化

一个可构建为单文件的中文交互式初始化脚本。服务器上直接运行脚本，按菜单选择即可；执行前会展示完整清单，只有明确输入 `y` 才开始修改系统。

适用于通过 SSH 管理、运行 systemd 的 Debian 13。需要 root 权限，以及包含 `trixie-security` 的 APT 软件源。服务器无需预装 Python；脚本自身使用 Bash、awk 和系统基础命令。保留云厂商恢复控制台；脚本不会自动重启。

## 构建和上传

开发机在项目目录执行：

```bash
bash build.sh
```

输出 **`dist/bootstrap.sh`**，包含全部模块。服务器只需要这一个文件，无需上传源码目录。仓库包含此单文件，修改源码后需重新构建并一同提交；也可通过 `bash build.sh /tmp/init-server.sh` 指定输出位置。

将示例中的 `your-server` 换成服务器地址：

```bash
scp dist/bootstrap.sh root@your-server:/root/bootstrap.sh
ssh root@your-server
bash /root/bootstrap.sh
```

后续运行也使用同一条命令，不需要输入配置参数或运行 ID。文件可以改名，可以从任意工作目录调用。

普通 sudo 管理员需要保留 SSH 会话信息，以便验证新连接与公钥认证：

```bash
sudo --preserve-env=SSH_CONNECTION,SSH_USER_AUTH bash /path/to/bootstrap.sh
```

构建和开发测试使用 Python 3，仅在开发机上需要。UFW、Fail2ban、自动更新工具自身的 Python 依赖由 APT 随软件包安装，不需要用户预先配置。

## 跟随向导配置

直接运行后显示：

```text
Debian 13 服务器初始化向导
回车使用默认值，Ctrl+C 随时退出。

1) 配置并初始化
2) 仅预览配置（不修改系统）
3) 查看当前状态
0) 退出
选择 [1]：
```

选择初始化或预览后，依次设置：

| 步骤 | 交互方式 | 回车默认值 |
| --- | --- | --- |
| 时区 | 保留当前 / 北京时间 / UTC / 自定义 | 保留当前时区；无法识别时使用 UTC |
| SSH 端口 | 输入新端口或跳过 | 不新增，保留现有端口 |
| SSH 来源 | 所有地址 / 当前管理 IP / 指定 IP 和网段 | 所有地址 |
| 公钥导入 | 跳过 / 本地公钥文件 / GitHub 账号 | 跳过 |
| 登录策略 | 已验证公钥会话才显示关闭密码选项；非 root sudo 会话还可选择禁止 root 登录 | 保留现有策略 |
| 业务端口 | 只放行 SSH / 网站 HTTP 和 HTTPS / 自定义 | 不新增业务端口 |
| Fail2ban 白名单 | 输入可信 IP 或网段，多个用逗号或空格分隔 | 不添加额外白名单 |
| Docker | 是否安装官方 Docker Engine、Compose 和 Buildx | 不安装 |
| 高级设置 | 先询问是否展开，选择后才显示详细选项 | 跳过全部高级设置 |
| 最终确认 | 显示全部选择，再询问是否开始 | 取消，不执行 |

自定义业务规则会分别询问端口号、TCP/UDP 和来源，不需要记忆参数格式。无效的编号、端口和 IP 会要求重新输入。网段使用数字前缀的 CIDR 写法，例如 `192.0.2.0/24`、`2001:db8::/32`；不接受接口作用域标识或点分掩码。

向导收集配置期间不修改系统。选择预览、最终确认时回车、输入结束或在执行前按 Ctrl+C，都不会开始初始化。没有终端时不会自动执行；无人值守调用必须显式指定命令。

## 初始化完成后确认新连接

访问相关配置修改前，会备份 SSH、UFW、Fail2ban 配置并启动独立的 systemd 回滚定时器，默认确认窗口为 10 分钟。前面的软件更新耗时不占用窗口。

配置检查通过后：

1. 保留旧终端，它会等待确认或回滚结果；此时已经释放执行锁，不会阻止新连接确认或定时器回滚。
2. 在另一个终端重新建立 SSH 连接。如果增加了 SSH 端口，应使用新端口连接。
3. 再次运行同一个脚本，也可以运行旧终端显示的单文件恢复副本。
4. 脚本自动识别待确认状态，显示以下菜单：

```text
1) 确认：我已从新 SSH 连接登录
2) 立即回滚访问配置
3) 查看状态
0) 退出，保留定时回滚
选择 [0]：
```

选择 `1` 后，脚本仍会实际校验连接是否不同于原连接、登录用户及端口是否符合要求，并重新检查服务。旧连接不能冒充新连接确认。成功后才取消定时回滚，旧终端会显示完成。

选择 `2` 需要再明确确认一次。直接回车退出不会取消定时回滚；旧终端按 Ctrl+C 也只退出等待。超时或检测到访问配置应用失败时，会恢复访问配置。回滚失败会保留待确认状态和备份，并由定时服务重试。

回滚程序保存的是完整单文件副本，删除或替换原上传文件不会破坏已建立的恢复任务。定时器使用持久化日历时间，重启后错过截止时间也会触发恢复。

## 默认执行内容

顺序为环境检查 → 软件更新和安装 → 时间和自动更新 → 日志和内核配置 → 清理缓存 → 备份访问配置和启动回滚保护 → SSH/UFW → Fail2ban → 验证 → 等待新连接确认。

| 模块 | 行为 |
| --- | --- |
| 环境检测 | Debian 13、root、systemd、SSH 会话、磁盘空间、DNS、架构、防火墙服务冲突 |
| 系统更新 | 更新 APT 索引并升级现有软件；检查安全源；等待 APT 锁最多 120 秒 |
| 基础工具 | curl、wget、sudo、vim-tiny、less、zip/unzip、htop、dnsutils、ping、netcat、lsof、rsync 等 |
| 时间同步 | 保留正在运行的 chrony、ntpsec 或 timesyncd，否则启用已有提供者或安装 timesyncd |
| 自动更新 | 仅自动安装 Debian 安全源更新，不自动重启或删除依赖 |
| 日志 | journald 持久化，最大 200M、尽量保留 500M 空间、最长保留 14 天；使用软件包自带 logrotate 规则 |
| 内核安全 | 限制内核指针、dmesg 可见性，启用硬链接和符号链接保护 |
| SSH | 公钥认证、禁止空密码；最多认证尝试 3 次，认证宽限期 30 秒，存活检查间隔 300 秒、最多无响应 2 次 |
| UFW | 拒绝入站、允许出站，支持 IPv4/IPv6，日志级别 low，开机启动 |
| Fail2ban | 使用 systemd journal；10 分钟失败 5 次封禁 1 小时，通过 UFW 封禁 |
| 清理 | 清理下载的 APT 包缓存，不默认删除依赖 |

首次完整升级也会安装常规更新；“仅安全更新”指后续自动更新。SSH 存活检查不是无键盘输入超时。

已有 UFW 规则会保留，不会清空。选择“只放行 SSH”指不新增业务规则，已有业务放行仍然有效。选择所有 SSH 来源时，新增的全来源放行可能扩大原有 SSH 访问范围。Fail2ban 白名单和 UFW 来源限制分别配置；默认白名单只有回环地址。UFW 封禁动作会封禁来源的全部入站流量。

脚本拒绝与运行中的 firewalld、nftables、netfilter-persistent 服务混用，也不支持 ssh.socket 激活方式。手工配置的规则仍需管理员检查。Docker 发布的端口可能绕过普通 UFW 入站规则，参见 [Docker 防火墙说明](https://docs.docker.com/engine/network/packet-filtering-firewalls/)。

## 安装 Docker

在向导的 Docker 问题回答 `y`，最终清单会显示将安装 Docker。安装使用 [Docker 官方 Debian APT 方案](https://docs.docker.com/engine/install/debian/)，包括：

- `docker-ce`：Docker Engine。
- `docker-ce-cli`：命令行工具。
- `containerd.io`：容器运行时。
- `docker-compose-plugin`：`docker compose`。
- `docker-buildx-plugin`：`docker buildx`。

支持 amd64、arm64、armhf 和 ppc64el。脚本备份并配置官方签名密钥与 `docker.sources`，安装仓库候选版本；已有官方版可能补齐或更新组件。遇到 `docker.io`、发行版 `containerd/runc` 等冲突包时会在初始化前退出，需先自行处理迁移，不会自动卸载它们。如果其他 APT 文件已经声明 Docker 源，先合并到 `docker.sources`，避免重复源和签名配置冲突。

下载和安装发生在回滚倒计时之前。首次安装的服务会临时禁止自动启动，完成 UFW 配置后再解除限制并启动 Docker、containerd，设置开机启动。检查使用本机 Unix socket 验证服务，并输出 Engine、Compose、Buildx 版本，不依赖拉取测试镜像。

Docker 使用 root 或 sudo 管理；脚本不自动把用户加入 docker 组，也不覆盖 `daemon.json`。安装或升级及容器数据不属于访问配置回滚范围。

**容器发布端口需单独控制访问。**本脚本的 UFW 业务端口规则不能保证限制 Docker 的发布端口，也不会自动生成 DOCKER-USER 规则或禁用 Docker 的防火墙管理。通过反向代理访问的容器可绑定本机回环地址；公网发布的容器需按实际部署设置访问策略。

## 高级设置与公钥认证

展开高级设置后可以选择：BBR、Swap 或 ZRAM、文件描述符上限、主机名、DNS、删除无用依赖、确认窗口长度。默认都不修改。

- Swap 仅支持 ext4/xfs，大小显式选择，已有管理文件不会重新格式化或自动调整大小。
- ZRAM 在手动重启后生效；同一次运行不能同时选择 Swap 和 ZRAM。
- 文件描述符上限影响新登录和未来的服务，已有进程不变。
- DNS 仅支持已有且管理 resolv.conf 的 systemd-resolved，不重写 resolv.conf；接口或 DHCP DNS 仍可能参与解析。
- 主机名设置会同时更新 hosts，并保留旧别名。

公钥可以从文件或 GitHub 账号导入到已有用户；不会自动创建用户或修改 sudo 权限。导入器逐行验证，不接受私钥、DSA 或带限制选项的输入；已有密钥的限制选项会保留。使用 GitHub 来源前应核对账号和密钥。

首次运行缺少 `SSH_USER_AUTH` 认证证明时，向导保留登录策略。完成初始化并确认后，通过公钥新建 SSH 会话再运行向导，才显示关闭密码认证选项；非 root sudo 管理员还能选择禁止 root 登录。关闭密码同时关闭键盘交互认证，使用该方式进行 MFA 的环境应保留。

SSH 配置写入 `/etc/ssh/server-bootstrap.conf`，主配置前置对应 Include。会检查当前来源、管理用户和 root 的有效策略；其他自定义 Match 例外仍由管理员审查。

## 备份与恢复范围

运行目录位于 `/var/lib/server-bootstrap/runs/`，仅 root 可访问，包含原始配置、恢复脚本和运行状态。待确认期间避免同时手工修改相关配置，恢复会还原快照。

自动恢复只负责 SSH、UFW、Fail2ban 以及本次导入密钥涉及的 `.ssh` 目录。**不会降级软件包，也不会撤销前面设置的时区、日志、内核参数和其他系统选项。**这些配置另有原文件备份，可根据清单人工恢复。

恢复依赖 systemd、磁盘和服务正常工作，不能修复云安全组、上游网络或系统损坏。

## 自动化接口和开发验证

参数接口保留给自动化场景，普通使用无需接触：

```bash
bash dist/bootstrap.sh --help
bash dist/bootstrap.sh plan
```

`apply`、`status`、`confirm RUN_ID`、`rollback RUN_ID` 仍可显式调用。命令行接口的默认时区仍为 UTC；交互向导默认保留当前时区。

自动化安装 Docker 可使用 `apply --docker`，只预览可使用 `plan --docker`。

本地测试包含真实伪终端交互、取消/EOF 不执行、参数组合、自动识别待确认状态、释放锁后等待、单文件构建和恢复副本：

```bash
python3 -m unittest discover -s tests -v
bash build.sh
```

Debian 13 实际解析器检查：

```bash
docker run --rm \
  --mount "type=bind,source=$PWD,target=/source,readonly" \
  debian:trixie-slim bash /source/tests/debian-config.sh
```

容器检查验证 ShellCheck、OpenSSH/Fail2ban 配置、UFW dry-run、APT 配置和 systemd 单元。公网重连、断线和重启回滚仍需在有恢复控制台的测试虚拟机上验证。

验证 Docker 官方软件源和软件包安装（不启动嵌套 Docker daemon，不挂载宿主机 Docker socket）：

```bash
docker run --rm \
  --mount "type=bind,source=$PWD,target=/source,readonly" \
  debian:trixie-slim bash /source/tests/docker-packages.sh
```

在未安装 Python 的干净容器中校验单文件地址检查、配置编辑和公钥合并：

```bash
bash build.sh
docker run --rm \
  --mount "type=bind,source=$PWD,target=/source,readonly" \
  debian:trixie-slim bash /source/tests/no-python.sh
```
