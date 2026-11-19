# DSH 多 agent 并发编排 Skill

> 多任务并行时，先判定值不值得开并发，再拆分互不重叠的写作用域，最多 1-2 个 teammate 并行推进，最后由 Lead 统一收口验收。
>
> A concurrency-orchestration skill for DeepSeek Harness (DSH): decide → split → spawn (max 2) → verify.

## 它解决什么问题

单 agent 串行做 N 件事，墙钟时间线性增长；盲目开并发，写冲突与收口混乱又会吃掉全部收益。
本 skill 只做一件事：**把并发的代价压到可控**，让「结果可验证」这个前提不被并行破坏。

## 五条硬规则

| # | 规则 | 判据 |
|---|---|---|
| 1 | 三条判据全过才并发 | 可切分（无硬依赖）、每片 ≥15 分钟、write_scopes 无交集 |
| 2 | 硬上限 2 个 teammate | 第 3 片起用 `blocked_by` 排队 |
| 3 | 同一时刻最多 1 个 impl | 两个 impl 并存必然撞文件 |
| 4 | 拆分阶段就写死产物路径 | 写不出路径 = 还没拆清楚 |
| 5 | Lead 独占收口，只认产物 | Test-Path / 退出码 / 验收节，不采信「我做完了」 |

## 安装

把本仓库的 `SKILL.md` 放到任一被扫描的 skill 根目录（目录 bundle 形式）：

| 作用域 | 路径 |
|---|---|
| 项目级 | `<workspace>/.dsh/skills/multi-agent-concurrency/SKILL.md` |
| 用户级 | `<dsh-home>/skills/multi-agent-concurrency/SKILL.md` |

文件系统 skill provider 会在数秒内发现新文件并刷新目录，无需重启 DSH。

## 让它自动生效（推荐）

skill 本身只在被加载时生效。要让它「不问用户、自动触发」，在项目 `AGENTS.md` 的规则表里加一行：

```
| **A-08** 并发自动触发 | ≥2 个独立可并行子任务即自动加载 `multi-agent-concurrency`，不等用户点名 | 1-2 个 teammate；write_scopes 无交集；Lead 收口只认产物 |
```

AGENTS.md 会随每轮会话注入，等价于把「该并发时并发」变成默认行为。

## 工作流五步

```text
① 拆      写下三列表：片名 / 产物路径 / 写作用域 / 前置依赖
② 建任务  先 team_task_create（含 write_scopes），再 spawn
③ spawn   1-2 个，同一消息里一起发，然后自己继续干 Lead 的活
④ 观察    wait_agent ≤120s，超时先 list_agents 再决定，不原地重试
⑤ 收口    Lead 逐片验产物 → 越界写检查 → 自跑总验证 → 入库
```

## 目录结构

```
.
├── SKILL.md              # 主编排规程（放 skill 根即可用）
├── docs/
│   └── workflow.md       # 三层自动化工作流：会话层 / 事件层 / 时间层
├── examples/
│   └── briefs.md         # 可直接复制的侦察片 / 实现片 brief
├── scripts/
│   └── who-locks.ps1     # Windows 句柄持有者定位（排 EIO/文件占用）
├── LICENSE
└── README.md
```

## 配套脚本：who-locks.ps1

Windows 上排查「文件正在使用 / EIO / ReplaceFileW」时，别猜同步盘，直接定位持有者：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\who-locks.ps1 -Path "D:\work\out\report.md"
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\who-locks.ps1 -Path "reports" -Json -Reveal
```

| 退出码 | 含义 |
|---|---|
| 0 | 找到持有者，先关它再重试 |
| 1 | 无持有者，锁不是原因，去查权限/内容/过滤器驱动 |
| 2 | 缺 handle64.exe（Sysinternals Handle） |
| 3 | 参数错误 |

依赖 `handle64.exe`，默认查找顺序：`$env:DSH_HANDLE64` → `D:\work\tools` → `E:\tools` → 脚本同级目录 → PATH。

## 实测结论（为什么这样设计）

跨进程受控实验（P/Invoke `ReplaceFileW`）：

| 持有者共享模式 | ReplaceFileW | Win32 错误 |
|---|---|---|
| `ReadWrite`（不含 Delete） | 失败 | 32 ERROR_SHARING_VIOLATION |
| `None`（独占） | 失败 | 32 ERROR_SHARING_VIOLATION |
| `ReadWrite \| Delete` | 成功 | — |

决定成败的是 **FILE_SHARE_DELETE**，不是「有没有被独占打开」。`1175 ERROR_CANCELLED` 在纯文件锁场景没有复现，只在过滤器驱动（同步客户端 / 杀软）介入时出现。

## 反模式

| 反模式 | 后果 | 正确做法 |
|---|---|---|
| 开 3 个以上 teammate | 写冲突率高于收益，收口成本爆炸 | 排队 + blocked_by |
| 两片 write_scopes 重叠 | advisory 不拦，最后互相覆盖 | 拆到目录级隔离 |
| 只派活不写产物路径 | 收口时无法判定完成 | 拆阶段就写死路径 |
| Lead 空等 wait_agent | 浪费并发收益 | 自己那份活先干完 |
| 采信「我做完了」 | 验收失效 | 只认 Test-Path / 退出码 |
| 收口阶段继续分派 | 并行已无收益，只增噪声 | Lead 一把改完 |

## 许可

MIT
