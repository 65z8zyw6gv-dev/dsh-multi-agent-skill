---
name: multi-agent-concurrency
description: 多任务并行时的团队编排规程：判定是否值得开并发，把工作拆成互不重叠的写作用域，最多用 1-2 个 teammate 并发推进，并由 Lead 统一收口验证。
whenToUse: 当一轮里有 2 个以上彼此独立、各自要跑 15 分钟以上的子任务时；或用户明确要求"开多个 agent 一起做""并发跑"时。单文件改动、单点排错、一次性问答不要用。
---

# 多 agent 并发编排（1-2 并发上限）

目标：**在保住"结果可验证"的前提下并行**。并发的收益来自墙钟时间，代价来自写冲突和收口混乱；本 skill 只做一件事——把代价压到可控。

## 自动触发（无需用户点名）

AGENTS.md 的 **A-08** 已经把本 skill 挂成自动项。所以按下面判断，**不要问用户"要不要并发"，直接开**：

```
出现 ≥2 个子任务
  ├─ 每片都有独立产物路径 + 预计 ≥15 分钟 + 写作用域可隔离
  │    → 自动按本规程 spawn（1-2 个），同一消息里一起发
  └─ 任一条件不满足 → 单干，一句话说明为什么没并发（不超过一行）
```

自动触发的典型信号（命中即算）：跑两个以上不同目录的改造、一边做实现一边要报告、批量处理 N 个互不相关的目标、改代码同时要验证、用户一次抛出多条互不相干的要求。

**唯一例外**：任务涉及同一批文件的修改、或后一步必须看前一步的具体输出 → 串行，不并发。

## 0. 默认单干

**默认是 Lead 自己干。** 只有同时满足下面三条才开并发，缺一条就单干：

| 判据 | 说明 | 反例 |
|---|---|---|
| 可切分 | 子任务之间没有"必须等前一步产出"的硬依赖 | 先解密再分析同一份样本 |
| 单片 ≥15 分钟 | 拆完每片都得有实体工作量，不是转发消息 | "你去看看这个文件夹" |
| 写作用域不重叠 | 两片改的文件集合交集为空 | 两人都改 `AGENTS.md` |

派生的第四条判据（结果只认产物，A-07）：**每片必须能给出可检验的产物**——文件、退出码、测试输出、报告路径。只产出"意见"的片子不派给 teammate，Lead 自己想。

## 1. 规模上限

- **并发 teammate 最多 2 个**（Lead + 2 = 3 个执行体）。这是硬上限，不是建议。
- 第 3 个及以后的任务：建 shared task 排进 `blocked_by`，等前两片 `complete` 后再 `send_message` 唤醒或新 spawn。
- 理由：本机 1 个 DSH 实例共享同一个工作目录与 PowerShell 会话，第 3 个并发带来的写冲突概率超过它省下的时间。

## 2. 五步流程

### 步骤 1｜拆（写下三列表，不要只在脑子里拆）

```
片名 | 负责产物（路径） | 写作用域（前缀） | 前置依赖
A 侦察 | reports/recon.md | reports/ | 无
B 实现 | src/feature_x/ | src/feature_x/ | 无
C 验证 | reports/verify.md | reports/verify/ | A、B
```

**每一片的产物必须是一个具体路径。** 写不出路径 = 还没拆清楚，回到步骤 0。

### 步骤 2｜建 shared task（先建任务，再 spawn）

```ts
await tools.team_task_create({
  subject: "侦察：整理 TARGET 的入口与配置",
  description: "目标：产出 reports/recon.md，覆盖 入口清单/配置项/风险点。验收：文件存在且三节齐全；不改 src/ 下任何文件。",
  write_scopes: ["reports/"],
});
```

要点：
- `write_scopes` 必须写，且两片之间**不允许重叠**。重叠只是 advisory，不会拦你，所以靠人守。
- 依赖用 `blocked_by: [前置 task id]` 表达，不要用"等消息"表达。

### 步骤 3｜spawn（一次消息里一起发，别串行等）

两条 `spawn_teammate` 放在**同一个 assistant 消息**里，然后立刻回去做 Lead 自己那份活。

```ts
await tools.spawn_teammate({ name: "recon-a", description: "侦察 TARGET 并出报告", prompt: RECON_BRIEF });
await tools.spawn_teammate({ name: "impl-b", description: "实现 feature_x", prompt: IMPL_BRIEF });
```

**BRIEF 必含 7 项**（缺一项就别 spawn，队友会跑偏）：

```
1. 目标：一句话说清要交付什么
2. 产物：绝对路径或工作区相对路径（唯一硬判据）
3. 写作用域：只许写 X/ 与 Y/，其它一律不动
4. 禁改清单：AGENTS.md / memory/ / .credentials.yaml / 他人产物
5. 验收判据：跑哪条命令、看哪个退出码、文件里必须有哪几节
6. 汇报格式：结论 3 行 + 产物路径 + 未解决项 + 建议（≤300 字）
7. 技能要求：开工前先看可用 skill 与 MCP 目录，命中就加载；本机只有 PowerShell 5.1，脚本用
   powershell -NoProfile -ExecutionPolicy Bypass -File 跑，改 .ps1 记得补 UTF-8 BOM
```

给 fresh 队友的 brief 必须自包含：它看不到你的对话历史。别写"按刚才说的那样"。

### 步骤 4｜观察节拍

```
done? → 先 list_agents 看是否有人 running/provisioning
      → 有人跑：自己继续干 Lead 的活，不要空等
      → 需要收结果：wait_agent({ timeout_ms: 120000 })
      → 超时回来必须重新 list_agents + team_task_list，不要原地重试
      → 队友 inactive 且没交付：send_message 追加一次明确指令，不重复原始 brief
      → 队友跑偏：interrupt_agent 打断，然后 send_message 给纠正后的单点指令
```

**禁止**：轮询 `job_list`/反复 `wait_agent` 空转；禁止对同一片连续两次用相同措辞催（本机审计已证明这是无效模式，第二次必须换假设）。

### 步骤 5｜收口（Lead 独占，不许外包）

1. `team_task_list({ status: "completed" })` 核对每片是否真完成（不是"说完成了"）。
2. 逐片 **只认产物**：`Test-Path` / 退出码 / 文件里的验收节。缺一项就 reopen。
3. `write_scopes` 交叉检查：`git status --porcelain` 或按目录 diff，确认没有越界写。
4. Lead 自己跑一遍总验证（测试、命令、页面），**不采信队友的自述**。
5. 冲突或半成品：由 Lead 统一改，不再分派——收口阶段并行已经没收益。
6. 入库：`memo.ps1 session -Text "本轮做了什么/结论/卡点" -Tag "..."`，一条即可。

## 3. 角色三选（不要发明第四种）

| 角色 | 适合 | 产物 | 典型时长 |
|---|---|---|---|
| 侦察 / recon | 检索、扫描、读代码、查文档 | 一份报告 .md | 10-30 min |
| 实现 / impl | 写一个独立模块、脚本、页面 | 代码目录 | 30-90 min |
| 验证 / verify | 复核别人产物、跑测试、找反例 | 验证报告 + 退出码 | 10-20 min |

同一时刻**最多一个 impl**。两个 impl 并发就必然撞文件；要做两件实现，排队。

## 4. 反模式表

| 反模式 | 为什么坏 | 正确做法 |
|---|---|---|
| 开 3 个以上 teammate | 写冲突率高于收益，收口成本爆炸 | 排队 + blocked_by |
| 两片 write_scopes 重叠 | advisory 不拦，最后互相覆盖 | 拆到目录级隔离 |
| 只派活不写产物路径 | 收口时无法判定完成 | 拆阶段就写死路径 |
| Lead 空等 wait_agent | 浪费并发收益 | 自己那份活先干完 |
| 采信"我做完了" | 违反 A-07 | Test-Path / 退出码 / 验收节 |
| 收口阶段还继续分派 | 并行已无收益，只增噪声 | Lead 一把改完 |
| 队友改 AGENTS.md / memory | 规则与知识库被并发污染 | 写进禁改清单 |

## 5. 复制即用的两段 brief

**侦察片**
```
你是 recon-a，只做侦察，不改任何源码。
目标：摸清 TARGET（<具体路径或 URL>）的入口、配置、依赖与风险点，产出 reports/recon-<日期>.md。
写作用域：reports/ 下新建文件；禁止改动其它任何路径。
禁改：AGENTS.md、memory/、.credentials.yaml、src/ 下任何文件。
验收：reports/recon-<日期>.md 存在，含「入口清单/配置项/风险点/未知项」四节，每条结论带证据（命令输出或文件行号）。
汇报：≤300 字，格式 = 结论3行 / 产物路径 / 未解决项 / 建议。
环境：只有 PowerShell 5.1；开工前先看可用 skill 与 MCP 目录，命中即加载。
```

**实现片**
```
你是 impl-b，只改 src/feature_x/。
目标：实现 <功能一句话>，跑通 <入口命令>。
写作用域：src/feature_x/ 下全部文件；reports/impl-b-notes.md 记录决策。
禁改：src/ 其它子目录、AGENTS.md、memory/、他人产物、依赖清单（要加包先报告）。
验收：<命令> 退出码 0；<测试文件> 全通过；改动清单 ≤15 个文件。
汇报：≤300 字，格式 = 结论3行 / 产物路径 / 未解决项 / 需要 Lead 决策的点。
环境：只有 PowerShell 5.1；.ps1 改动后确认 UTF-8 BOM；开工前先看可用 skill 与 MCP 目录。
```

## 6. 一页检查清单

开工前：□ 三条判据都过 □ 每片有产物路径 □ write_scopes 无交集 □ ≤2 片并发 □ brief 七项齐
进行中：□ Lead 自己在干活 □ wait ≤120s □ 超时先 list_agents 再决定 □ 催第二次换措辞
收口时：□ 逐片 Test-Path/退出码 □ 越界写检查 □ Lead 自跑总验证 □ 冲突 Lead 自己改 □ memo session 入库
