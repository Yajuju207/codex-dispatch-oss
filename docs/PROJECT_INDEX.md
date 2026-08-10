# Project Index v0.1

`Project Index` 是 Project Discovery 与 Fast Router 之间的本机缓存层。它把发现器返回的合法 Git 项目整理为一个体积受控、顺序稳定的 JSON 索引，使后续路由无需每次重新枚举整个工作区。

## 目标

v0.1 只解决一个问题：为本机快速路由提供可靠的项目身份与路径关键词。

它不会：

- 调用 GitHub API 或访问网络；
- 读取源码、README、配置文件正文或 Git 对象内容；
- 修改工作树、Git index、分支或远端；
- 运行 Codex；
- 决定最终路由结果。

## 输入

构建器复用：

- `Load-CodexDispatchConfig.ps1`
- `Discover-CodexProjects.ps1`

只有发现状态为 `ok`、本地路径仍位于 `workspace.root` 内且可再次通过 Git 根目录验证的项目才进入索引。

## 使用方式

在包含 `config.local.json` 的目录中运行：

```powershell
.\scripts\Build-CodexProjectIndex.ps1
```

默认输出到当前目录的：

```text
project-index.json
```

也可以显式指定运行配置与输出路径：

```powershell
.\scripts\Build-CodexProjectIndex.ps1 `
    -ConfigPath .\config.local.json `
    -OutputPath .\.codex-dispatch-state\project-index.json
```

输出文件属于本机运行状态；仓库 `.gitignore` 已忽略 `project-index.json`。

## 索引内容

顶层格式固定为：

```json
{
  "version": 1,
  "projects": []
}
```

每个项目包含：

- `name`：Discovery 返回的项目目录名；
- `localPath`：规范化绝对路径，仅存在于本机索引；
- `githubRepository`：可识别时为 `owner/repository`，否则为 `null`；
- `tokens`：供 Fast Router 使用的稳定、去重关键词；
- `trackedPathCount`：Git 报告的 tracked path 总数；
- `indexedTrackedPathCount`：实际参与 token 构建的 tracked path 数；
- `truncated`：是否因 v0.1 上限而只索引了 tracked path 的前一部分。

不写入时间戳，以保证相同项目状态可以产生稳定输出。

## token 来源

v0.1 的 token 全部规范化为小写，只来自：

1. 项目目录名；
2. GitHub `owner/repository` 与 repository 名；
3. `git -c core.quotepath=false ls-files` 返回的 tracked path 的路径段、文件名和不带扩展名的文件名。

例如 tracked path：

```text
src/Relics/EternalWaiting.cs
```

可以贡献：

```text
src
relics
eternalwaiting.cs
eternalwaiting
```

构建器只读取 Git 返回的**路径字符串**，不会打开 `EternalWaiting.cs`。

## 体积上限

为了避免大型 monorepo 把索引无限放大，v0.1 使用固定安全上限：

- 每个项目最多使用排序后的前 5000 条 tracked path 构建 token；
- 每个项目最多保留 4096 个唯一 token；
- token 长度为 2–128 个字符；
- token 比较与去重大小写不敏感；
- 输出排序稳定。

超过 tracked path 或 token 上限时，`truncated=true`。项目仍然可路由，但 Fast Router 应把“缺少匹配 token”理解为可能需要 Slow Router，而不是认定项目不存在。

## 隐私与安全

Project Index 是 LOCAL 层数据，不应提交到公开仓库或复制到 Issue。

构建器：

- 仅执行 `git rev-parse --show-toplevel` 与 `git -c core.quotepath=false ls-files`；
- 使用 `--no-optional-locks`；
- 不执行 fetch、pull、push、status、diff 或任何网络操作；
- 不遍历 `.git`；
- 不跟随 reparse point 越过 `workspace.root`；
- 不读取 tracked file 的内容；
- 输出路径若已存在且是 reparse point，或父目录是 reparse point，则拒绝写入。

## 与 Fast Router 的关系

Fast Router 后续只消费 `project-index.json`，对用户任务进行低成本确定性打分。

Project Index 本身不包含打分阈值，也不实现 `minimumStrongScore` 或 `minimumLead`；这些属于 Fast Router 阶段。