# 三层自动化工作流

> 口径：只收「有触发器、有判据、有兜底」的链路。脚本存在但没人调用的，不算工作流。

## 1. 架构

```text
┌─ 会话层（每轮自动注入，不需要人记得）────────────────────────┐
│  AGENTS.md 规则表  A-01 写入定位 / A-02 质疑 / A-03 入账      │
│                   A-04 清理 / A-05 归因 / A-06 凭据 / A-07 结果│
│                   A-08 并发自动触发 → 本 skill                │
└──────────────────────────────────────────────────────────────┘
┌─ 事件层（出错那一刻触发）────────────────────────────────────┐
│  EIO / EBUSY / 文件占用  →  who-locks.ps1 -Path <目标>        │
│  失败 / 越界 / 泄露      →  错误台账追加一行                  │
│  同一 rootcause 达 3 次  →  升级为硬规则                      │
└──────────────────────────────────────────────────────────────┘
┌─ 时间层（无人值守，OS 计划任务）─────────────────────────────┐
│  周日 10:00  残留巡检（dry-run）  →  成功则记录心跳            │
│  周一 09:00  失约检查            →  异常则写入当日流水         │
│  每日 23:30  知识库镜像备份      →  成功则记录心跳            │
└──────────────────────────────────────────────────────────────┘
                    ↑ 心跳脚本监控上面三层是否真的发生过
```

## 2. 为什么要三层

- 只有会话层：规则在手，但没人真的去做。
- 只有事件层：出错能记，但重复发生的错不会被升级成规则。
- 只有时间层：定时任务自己也会挂，没人发现它挂过。

三层互为兜底：**规则约束行为，事件沉淀教训，时间层保证「定期动作」不依赖记性，心跳验证前三层没偷懒。**

## 3. 时间层落地（Windows 计划任务）

```powershell
# 用 ScheduledTasks 模块注册，避开 schtasks 的引号地狱
function New-DshTask($name, $script, $trigger, $desc) {
  $arg = '-NoProfile -ExecutionPolicy Bypass -File "' + $script + '"'
  $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
  $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
           -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $name -TaskPath '\DSH\' -Action $act -Trigger $trigger `
           -Settings $set -Description $desc -Force
}

# 只指向薄壳，业务逻辑留在脚本里
New-DshTask 'Janitor-DryRun-Sun' '<tools>\run-janitor.ps1' (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '10:00') '残留巡检 dry-run'
New-DshTask 'Review-Mon'          '<tools>\run-review.ps1'  (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At '09:00') '失约检查'
New-DshTask 'Backup-Daily'        '<tools>\run-backup.ps1'  (New-ScheduledTaskTrigger -Daily -At '23:30') '知识库每日备份'
```

| 任务 | 触发 | 成功判据 | 失败后的兜底 |
|---|---|---|---|
| `Janitor-DryRun-Sun` | 每周日 10:00 | 退出码 0 | 不记录心跳 → 心跳脚本 2 天后报 STALE |
| `Review-Mon` | 每周一 09:00 | 退出码 0 | 异常行自动写入当日流水 |
| `Backup-Daily` | 每日 23:30 | 退出码 0 且产物目录存在 | 不记录心跳 → 2 天后报 STALE |

要点：

1. **薄壳设计**：任务只调用 `run-*.ps1`，业务逻辑在独立脚本里。改逻辑不用重新注册任务。
2. **心跳双写**：脚本成功了才 `mark`，所以「有没有真跑过」可直接查询，不用去翻任务历史。
3. **退出码归一化**：robocopy 的 0-7 都算成功，脚本必须显式归一化，否则任务永远显示失败。

## 4. 判据一览

| 工具 | 用途 | 退出码判据 |
|---|---|---|
| 知识库脚本 | 主题卡 / 流水 / 索引重建 | 0 成功 |
| 残留巡检 | 默认 dry-run，加 `-Apply` 才移动 | 0 正常 / 2 源缺失 |
| 心跳 | `check` / `mark -Name` / `show` | 0 全 OK / 3 有失约 |
| 错误台账 | `list` / `stats` / `render` | 0 正常 / 3 坏行 / 4 需升级 |
| 备份 | 镜像 + 保留 N 份 | 0 成功 / 2 失败 |
| `who-locks.ps1` | 句柄持有者定位 | 0 有持有者 / 1 无 / 2 缺工具 / 3 参数错误 |

## 5. 台账的两个关键字段

| 字段 | 作用 |
|---|---|
| `escalated` | 标记某类错误已完成升级，统计时输出 `ACKED` 而非 `ESCALATE`，不再计入退出码 |
| `resolves` | 新记录引用被结账记录的 `time`，使原记录不再算 open，同时保持历史 append-only |

这两个字段解决一个真实矛盾：**错误次数已经触发升级、升级也已经做完，但累计计数不会消失**。
不改写历史行，只追加结账记录，是这类审计表的通用做法。

## 6. 日常节拍

| 频率 | 动作 | 谁做 |
|---|---|---|
| 每轮 | 规则自动生效；报错先跑 who-locks | 模型 |
| 每次踩坑 | 追加一条机制级 rootcause | 模型 |
| 每天 | 知识库备份 | 计划任务 |
| 每周日 | 残留 dry-run | 计划任务 |
| 每周一 | 失约检查 | 计划任务 |
| 每月 | 把出现 ≥3 次的错误升级为硬规则 | 人 + 模型 |

## 7. 撤销

```powershell
'Janitor-DryRun-Sun','Review-Mon','Backup-Daily' | ForEach-Object {
  Unregister-ScheduledTask -TaskPath '\DSH\' -TaskName $_ -Confirm:$false
}
```

计划任务只在任务库留条目，不写服务、不改系统策略、不动系统目录，撤销后无残留。
