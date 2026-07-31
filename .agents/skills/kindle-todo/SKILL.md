---
name: kindle-todo
description: 将中文自然语言待办整理为结构化任务，并在用户确认后创建、更新或完成 Notion 任务；适用于“记个待办”“提醒我”“修改待办”“标记完成”“同步到 Kindle”等请求，以及维护 Kindle AI Quota Dashboard 的 Notion 待办同步。
---

# Kindle 待办助手

## 目标

将 Notion 作为待办唯一数据源。识别自然语言中的任务、日期、优先级和 Kindle 显示意图，经过用户确认后写入 Notion；电脑端采集器再生成公开快照，Kindle 插件只读显示前三条。

## 解析字段

生成内部结构：

- `action`：`create`、`update`、`complete`、`list` 或 `sync`。
- `title`：去掉“提醒我”“帮我”等指令性前缀后的简洁任务标题，最多 80 个字符。
- `dueAt`：使用北京时间 `Asia/Shanghai`；只有用户明确提供日期时才填写，不要擅自猜测日期。
- `priority`：高、普通或低；未说明时使用普通。
- `status`：新建默认为未开始/待处理；以 Notion 数据库实际状态选项为准。
- `kindleVisible`：用户说“显示到 Kindle”或“记个待办”时默认为 true；用户说“不要显示”时为 false。
- `target`：更新或完成时记录匹配到的 Notion 页面。

## 写入前确认

创建、更新或完成 Notion 页面前，先向用户展示将要执行的变更并等待确认。以下情况必须追问：

- 日期或时间存在歧义。
- 找到多个同名或相似任务。
- 用户要求“完成”但无法唯一匹配任务。
- 任务可能包含会公开到 GitHub Pages 的敏感信息。

用户未确认时只给出解析结果，不写入 Notion。

## Notion 操作

使用已连接的 Notion 工作区和“Kindle 待办”数据库。更新页面前必须重新读取页面当前内容，保留用户没有要求修改的属性。不要删除或覆盖页面正文，不要把 token、页面正文或私密备注写入仓库。

数据库属性默认对应：

| Notion 属性 | 类型 | 映射 |
|---|---|---|
| 任务 | 标题 | `title` |
| 状态 | Status | `status` |
| 截止日期 | Date | `dueAt` |
| 优先级 | Select | `priority` |
| Kindle显示 | Checkbox | `kindleVisible` |
| Kindle置顶 | Checkbox | `pinned` |

完成任务时只修改状态为“完成”或数据库对应的完成状态。采集器会自动排除已完成任务，不要为了隐藏任务而删除页面。

## 本地与云端边界

- 在 ChatGPT/Codex 云端任务中，优先使用已授权的 Notion connector 读写 Notion。
- 云端任务不得读取、猜测或要求用户复制本机 `NOTION_API_KEY`；不要把 token 写入仓库、日志或提示词。
- 云端任务不能假设能启动用户 Windows 的计划任务，也不能声称已经完成 GitHub Pages 发布，除非确实有对应工具和运行结果。
- 云端写入 Notion 后，电脑端的 Windows 计划任务会负责读取 Notion、构建 `dist` 并发布到 GitHub Pages；如果用户要求立即同步但当前环境不是本机，应说明需要在 Windows 项目目录执行同步脚本。

## 同步 Kindle

用户明确要求立即同步时，在本机项目根目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\update-dashboard.ps1
```

同步前确认工作区没有用户未提交的跟踪文件修改；同步脚本会读取 Notion、构建 `dist` 并推送公开快照。没有明确要求立即同步时，说明电脑端计划任务会在下一轮采集，Kindle 插件每分钟检查一次。

Kindle 端只显示排序后的前三条，排序为置顶、截止日期、优先级。不要伪造未从 Notion 读取到的任务或状态。

## 安全规则

- Notion 是唯一任务来源；不要在 Kindle 上直接编辑待办。
- 不要把未确认的自然语言直接写入 Notion。
- 不要猜测截止日期、重复创建同一任务或静默完成不明确的任务。
- GitHub Pages 默认公开；涉及敏感信息时提醒用户取消 `Kindle显示` 或改用私有托管。
- Notion 不可用时保留现有缓存，明确报告失败原因，不伪造同步成功。
