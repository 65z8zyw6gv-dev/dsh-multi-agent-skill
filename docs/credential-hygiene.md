# 凭据卫生：为什么 agent 不能「读一眼」凭据文件

> 本文来自一次真实事故：为了让 agent 确认某个配置文件里是否明文存 token，直接读取了文件内容。
> 结论不是「口径错了」，而是——**读的那一刻，token 就已经进了会话日志**。

## 事故形态

```text
错误动作：读取 ~/.config/gh/hosts.yml 核对 token 是否存在
真实后果：读取动作本身把 gho_ 开头的 token 写进会话日志
          → 日志落盘 + 上送 → 二次泄露
```

这类泄露有个特点：**看不见、不可撤销、且发生在「只是想确认一下」的瞬间。**

## 判据：什么算「读」

| 动作 | 算不算读 | 说明 |
|---|---|---|
| `Get-Item` 看大小/时间 | 不算 | 只看元数据 |
| `Test-Path` | 不算 | 只看存在性 |
| `Select-String` 且只输出到冒号前 | **边界** | 只取键名，不取值 |
| `Get-Content` / `read` / `cat` | **算** | 值进上下文即进日志 |
| 把文件贴进对话 | **算** | 同上传 |

规则一句话：**读键名，不读值；看存在，不看内容。**

## 正确做法

### 1. 判断存在性，不打开

```powershell
Get-Item $env:APPDATA\GitHub CLI\hosts.yml | Select-Object Length, LastWriteTime
Test-Path $env:APPDATA\GitHub CLI\hosts.yml
```

### 2. 需要键名列表时，截断到分隔符

```powershell
# 只保留冒号之前的部分，值不会进入输出
Select-String -Path $file -Pattern '^\s*[^:#]+' | ForEach-Object {
  ($_.Line -split ':')[0]
}
```

### 3. 真正需要用时，走环境变量或进程内注入

```powershell
# 由用户在会话外设置，agent 只引用变量名
$env:GITHUB_TOKEN = (Read-Host -AsSecureString | ConvertFrom-SecureString -AsPlainText)
```

关键：**agent 只操作变量名，从不打印值。**

## 一旦读过，处置顺序

| 顺序 | 动作 | 理由 |
|---|---|---|
| 1 | **轮换**（吊销 + 重签） | 服务端的旧 token 不会因为你删日志而失效 |
| 2 | 清理本地副本（logout） | 降低明文驻留风险 |
| 3 | 记录一条机制级 rootcause | 防止同一个坑再踩 |
| 4 | 最后才考虑删日志 | 日志通常已多处落盘，删除收益最低 |

**顺序不能反。** 先删日志是自我安慰——泄露点不止一处，吊销才是唯一确定的止损。

## 检查清单

```text
□ 项目里是否存在 .env / *.pem / hosts.yml / .credentials.yaml
□ 这些路径是否被 .gitignore 排除
□ agent 的指令里是否明确写了「只读键名」
□ 是否有一条规则把「禁读凭据」写成硬性约束（本项目为 A-06）
□ 轮换流程是否只有一个人知道、是否有文档
```

## 与编排规程的关系

并发场景下这条更危险：**teammate 是独立上下文，它不知道主会话已经读过什么。**
所以凭据禁令必须写进每个 brief 的「禁改清单」，而不是只写在主会话规则里。

参见 [SKILL.md](../SKILL.md) 第 5 节「复制即用的两段 brief」——禁改清单里默认包含凭据文件。
