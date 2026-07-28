# Auto Twitter Marketing 使用方案

本文档说明本地 `fkst-hosted` 如何通过 public package repo 跑通策略导入、周内容导入、X 发布、每日定时发布，以及新增的 Marketing Radar 能力。

## 范围

目标：

- 使用 GitHub Issue 作为运营输入面。
- 业务能力放在 `fkst-packages-market-hzz`，不改 `fkst-hosted` 核心。
- 让 `fkst-hosted` 从 public package repo 组合 package。
- 发布 X 时只通过 host broker 的 NyxID 服务，并强校验目标账号是 `hzz780`。

非目标：

- 不把 GitHub、LLM、X 的 raw credential 写入 repo、manifest 或 issue payload。
- 不把营销业务逻辑塞进 `fkst-hosted`。
- MVP 不做媒体上传和 thread 发布；当前 live X 发布是 text-only。

## 运行组合

使用 manifest：

```text
manifests/auto-twitter-marketing.json
```

组合 package：

```text
packages/github-proxy
packages/marketing-radar
packages/github-auto-twitter-marketing
packages/x-publisher
packages/lark-approval
packages/social-metrics
```

GitHub 工作 label：

```text
auto-twitter-marketing
```

所有输入 issue 都必须带这个 label。

## Host 配置

GitHub 写入由 hosted 环境控制：

```sh
FKST_GITHUB_WRITE=1
FKST_GITHUB_BOT_LOGIN=<github-app-bot-login>
FKST_DEVLOOP_MANAGED_BOT_LOGINS=<github-app-bot-login>
FKST_GITHUB_AUTHORIZED_LOGINS=<allowed-human-or-bot-logins>
```

真实 X 发布独立控制：

```sh
X_PUBLISH_WRITE=1
NYXID_X_SERVICE_SLUG=api-twitter-2-media
X_PUBLISH_EXPECTED_USERNAME=hzz780
```

`x-publisher` 会先通过 NyxID 调 `/users/me`。如果解析出来的 username 不是 `hzz780`，live 发布会被阻断。

LLM 配置属于 host 环境，不进入 package 源码：

```sh
LLM_BASE_URL=https://llm.aelf.dev/v1
LLM_MODEL=gpt-5.5
LLM_API_KEY=<secret>
```

## Issue 协议

### 策略导入

```md
type: strategy
project: chronoai
account: hzz780

定位：
- ...
```

预期结果：

- `github-auto-twitter-marketing.strategy_imported`
- GitHub 评论：`strategy imported`

### 周内容 / 内容日历导入

````md
type: weekly-content
project: chronoai
week: 2026-W31
strategy-ref: #24

tweet-text:
```
FKST live publish verification for hzz780 via NyxID.
```
````

预期结果：

- `github-auto-twitter-marketing.weekly_content_imported`
- GitHub 评论：`weekly content imported`

### 单次发布

```md
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #25
mode: live
scheduled-at: 2026-07-28T11:10:00+08:00
```

预期结果：

- `github-auto-twitter-marketing` 发出 `x-publisher.x_publish_request`
- `x-publisher` 根据 `calendar-ref` 回源读取周内容 issue
- live gate 通过后，`x-publisher` 发布一条 text-only X
- GitHub 评论：`schedule publish live requested`

### 每日定时发布

```md
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #25
mode: live
recurrence: daily
time: 11:10
timezone: Asia/Shanghai
```

预期结果：

- 打开的 schedule issue 会被周期性 GitHub resync 观察到。
- 到达本地 `11:10` 后，package 会为当天 occurrence 发出一次 publish request。
- 同一天同一 occurrence 有 dedup，不会重复发。
- 测试完成后关闭该 schedule issue，避免第二天继续发。

### 雷达配置

```md
type: radar-config
project: chronoai
account: hzz780
cadence: daily
timezone: Asia/Shanghai
topics: FKST, hosted automation, AI workflow
competitors: example-a, example-b
```

预期结果：

- `marketing-radar.radar_config_imported`
- GitHub 评论：`radar config imported`

### 雷达信号

```md
type: radar-signal
project: chronoai
week: 2026-W31
topic: FKST hosted automation
source-url: https://github.com/aelf-hzz780/fkst-packages-market-hzz/issues/24
insight: GitHub issue inputs can drive strategy, weekly content, and scheduled X publishing.
priority: high
```

预期结果：

- `marketing-radar.radar_signal_imported`
- GitHub 评论：`radar signal imported`

### 雷达生成周内容

````md
type: radar-run
project: chronoai
week: 2026-W31
strategy-ref: #24
topic: FKST hosted automation
source-url: https://github.com/aelf-hzz780/fkst-packages-market-hzz/issues/24
insight: Local hosted can import issues and schedule X posts.
assignee: aelf-hzz780

tweet-text:
```
Radar generated test post for FKST auto-twitter.
```
````

预期结果：

- `marketing-radar.radar_brief_created`
- `marketing-radar` 发出 `github-proxy.github_issue_create_request`
- `github-proxy` 创建一个新的 `weekly-content` issue，并带上 `auto-twitter-marketing` label
- 新生成的周内容 issue 会继续被 `github-auto-twitter-marketing` 导入

### 已知 `calendar-ref` 时由雷达生成发布任务

```md
type: radar-run
project: chronoai
week: 2026-W31
calendar-ref: #25
mode: live
recurrence: daily
time: 11:10
timezone: Asia/Shanghai
assignee: aelf-hzz780
```

预期结果：

- `marketing-radar.radar_brief_created`
- `github-proxy` 创建一个新的 `schedule-publish` issue，指向 `#25`

## 当前边界

`github-proxy` 已支持创建 issue，并会写幂等 marker；但它当前不会把“新建 issue number”作为 package event 回传给上游。因此 MVP 采用可靠的两段式：

1. `radar-run` 创建 `weekly-content` issue。
2. 拿到实际生成的 issue number 后，把它作为 `calendar-ref` 创建 `schedule-publish` issue。

如果后续要完全自动闭环，需要新增 public seam，例如：

```text
github-proxy.github_issue_created
```

然后让 `marketing-radar` 消费这个事件并继续生成 schedule issue。

## 验收 Case

本地 `fkst-hosted` UI：`http://127.0.0.1:5280`
本地 API：`http://127.0.0.1:18082`

建议按下面顺序验收：

1. 创建 `strategy` issue，确认导入评论。
2. 创建 `weekly-content` issue，确认导入评论。
3. 创建到期的单次 `schedule-publish` issue，确认 hzz780 发出一条真实 X。
4. 创建接近当前时间的 daily `schedule-publish` issue，确认当前 occurrence 只发一次；测试后关闭 issue。
5. 创建 `radar-config` issue，确认雷达配置导入评论。
6. 创建 `radar-signal` issue，确认雷达信号导入评论。
7. 创建不带 `calendar-ref` 的 `radar-run` issue，确认自动生成新的 `weekly-content` issue，并被 auto-twitter 导入。
8. 创建带 `calendar-ref` 的 `radar-run` issue，确认自动生成新的 `schedule-publish` issue。
9. 用雷达生成的内容跑 live 发布，通过 NyxID 查询并确认 X tweet id。

## 运维说明

- 本地没有公网 webhook 时，hosted 依赖 GitHub poll/resync。可以通过主动 resync 或缩短本地 poll interval 来加速测试。
- `mode: shadow` 只生成预览，不发真实 X。
- `mode: live` 必须同时打开 GitHub 写入和 X 写入 gate。
- 同一个 issue 重跑是安全的；`dedup_key` 和 GitHub marker 会防止同一逻辑请求重复产生外部副作用。
