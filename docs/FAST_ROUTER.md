# Fast Router v0.1

`Fast Router` 是纯本地、确定性的项目候选评分器。它读取任务文本、运行配置和 `Project Index v1`，返回一个可解释的路由建议；它不会执行最终任务。

## 使用方式

```powershell
.\scripts\Fast-Route-CodexTask.ps1 `
    -Task '修复 EternalWaiting 卡牌' `
    -ConfigPath .\config.local.json `
    -IndexPath .\project-index.json
```

参数：

- `Task`：必需的非空任务字符串；
- `ConfigPath`：可选，沿用 `Load-CodexDispatchConfig.ps1` 的规则，默认是当前目录的 `config.local.json`；
- `IndexPath`：可选，默认是当前目录的 `project-index.json`。

Fast Router 只使用现有配置字段：

- `routing.fast.enabled`；
- `routing.fast.minimumStrongScore`；
- `routing.fast.minimumLead`。

它不会新增或推断配置字段。三个字段缺失或类型错误属于配置错误。

## 输入索引

Fast Router 只接受 `Project Index v1`。每个项目必须包含：

- `name`；
- `localPath`；
- `githubRepository`；
- `tokens`；
- `trackedPathCount`；
- `indexedTrackedPathCount`；
- `truncated`。

Fast Router 同时验证 Project Index v1 的生成上限：

- 每个项目最多 4096 个 `tokens`；
- 每个规范化 token 的长度必须为 2–128 个字符（忽略 separator）；
- `indexedTrackedPathCount` 最多为 5000，且不能大于 `trackedPathCount`。

每个 `localPath` 必须是绝对路径。Fast Router 使用 `GetFullPath` 做纯词法规范化，并要求结果严格位于配置的 `workspace.root` 目录分隔符边界之下；`workspace.root` 自身与相邻前缀（例如根目录 `D:\projects` 与候选 `D:\projects2\x`）都不属于合法项目范围。

缺失、损坏、不支持的版本或不符合 schema 的索引会抛出统一错误，不会静默返回 `no_match`。

## 规范化

所有比较使用 Unicode Form KC 和 invariant lowercase。

以下字符被视为等价 separator，并压缩为单个空格：

- `_`
- `-`
- `.`
- `/`
- `\`
- whitespace

其他标点也作为边界处理。ASCII identity 使用完整规范化词组匹配，避免 `app` 错误命中 `application`；包含非 ASCII 字符的 identity 支持在连续中文任务文本中匹配，因此 `请修改王二卡牌的路由` 可以命中项目名 `王二卡牌`。

实现不使用第三方分词器或依赖。

## Identity 评分

每个项目只保留一个最具体的 identity 信号：

| 信号 | 分数 |
| --- | ---: |
| 完整 `owner/repository` | 220 |
| 完整 project name | 180 |
| repository name | 180 |

完整 `owner/repository` 优先于较短的 repository name。与任一项目 identity 规范化后相同的索引 token 不再重复获得 token 分数。

## Token 评分

同一规范化 token 每个项目最多计分一次。长度计算忽略规范化 separator。

| token 长度 | 基础分 |
| --- | ---: |
| `>= 12` | 80 |
| `8–11` | 60 |
| `5–7` | 35 |
| `3–4` | 15 |
| `<= 2` | 0 |

如果 matched token 只存在于一个项目，再增加：

| token 长度 | 唯一性 bonus |
| --- | ---: |
| `>= 8` | 60 |
| `5–7` | 25 |

例如：

- 唯一 token `eternalwaiting` 长度为 14，得分为 `80 + 60 = 140`；
- 唯一 token `relics` 和 `powers` 各为 `35 + 25 = 60`，合计 120；
- 两个项目共享长度为 10 的 `dispatcher` 时，各得 60，没有唯一性 bonus。

## Stop tokens

以下内置弱证据不产生 token 分数：

```text
src source test tests doc docs script scripts build main readme license
config git github code app lib
```

Stop token 仍可作为项目的完整 identity。例如项目确实名为 `app` 时，完整 project name 仍是 180 分 identity 信号。

如果复合索引 token 的任一规范化组件位于 stop list，整条 token 都不产生 token 分数；例如 `readme.md` 和 `config_local` 不会绕过弱证据过滤。

## 判定

候选按以下顺序稳定排列：

1. score 降序；
2. 规范化 project name 的 ordinal 升序；
3. 规范化 local path 的 ordinal 升序；
4. 原始 name 和 local path 的 ordinal 升序。

定义：

- `topScore`：第一名得分；
- `lead`：第一名减第二名；没有第二名时等于 `topScore`。

状态：

- `strong`：`topScore >= minimumStrongScore` 且 `lead >= minimumLead`；
- `ambiguous`：存在正分，但未同时满足两个 strong 阈值；
- `no_match`：所有项目都是 0 分；
- `disabled`：`routing.fast.enabled=false`。

`disabled` 不读取 Project Index。配置或索引错误永远不会降级为 `no_match`。

## 输出

输出是 PowerShell 对象，固定 `version=1`：

```text
version
status
topScore
lead
selectedProject
candidates
```

`strong` 时，`selectedProject` 包含：

- `name`；
- `localPath`；
- `githubRepository`；
- `score`；
- `matchedSignals`。

`candidates` 最多返回确定性排序后的前三名。每个候选都带 `matchedSignals`；token signal 同时给出 `baseScore` 和 `uniqueBonus`，足以解释得分。`ambiguous`、`no_match` 和 `disabled` 的 `selectedProject` 为 `null`。

## 错误

Fast Router 自身、配置加载和 Project Index 错误统一为：

```text
Codex Dispatch 快速路由错误：...
```

系统错误不会被吞掉，也不会变成正常路由状态。

## 本地性与安全边界

Fast Router：

- 不调用网络；
- 不调用 Git；
- 不调用 Codex 或其他 LLM；
- 不运行 Project Discovery；
- 不重新构建 Project Index；
- 不读取任何项目文件正文；
- 不写入或修改 `project-index.json`；
- 不跟随作为 reparse point 的 Project Index。

它只读取 `config.local.json` 和 `project-index.json`，并把确定性 PowerShell 对象写到标准输出。

Fast Router 的输出只是路由建议，不是最终路径授权。Worker 在执行任何项目操作前仍必须依据当时的 `workspace.root` 重新校验 workspace 边界。
