# Notion 待办与 Kindle 同步

这套方案把 Notion 作为待办的唯一事实来源：电脑端定时读取 Notion，只把勾选了“Kindle显示”且尚未完成的事项写入公开快照；Kindle 只读快照，不直接写 Notion。

## 1. 创建 Notion 数据库

创建一个数据库，例如“Kindle 待办”，设置以下属性：

| 属性名 | 类型 | 建议值 |
| --- | --- | --- |
| `任务` | 标题 | 待办内容 |
| `状态` | 状态或选择 | `未开始`、`进行中`、`完成` |
| `截止日期` | 日期 | 可选 |
| `优先级` | 选择 | `高`、`普通`、`低` |
| `Kindle显示` | 复选框 | 要显示时勾选 |
| `Kindle置顶` | 复选框 | 可选；置顶时勾选 |

电脑端只同步前三条，排序规则是：置顶优先，其次截止日期较早，最后优先级较高。未完成但没有勾选“Kindle显示”的任务不会公开。

## 2. 分享数据源给 Notion connection

在 Notion 数据库右上角打开“连接 / Connections”，把用于本项目的 Notion integration 或 connection 添加进去。没有这一步时，API 通常会返回 404，不能说明数据源 ID 一定错误。

## 3. 在 Windows 上启用 Notion

在项目目录打开 PowerShell，运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\enable-notion-todo.ps1 -DataSourceId "你的数据源 ID"
```

脚本会在 PowerShell 中安全提示输入 Notion token，并把它保存为当前 Windows 用户的环境变量；token 不写入 `config.json`、Git 或 GitHub Pages。

完成后重新启动“Kindle AI Quota Dashboard Update”计划任务，或退出 Windows 账户后重新登录，使计划任务获得新的用户环境变量。

## 4. 验证同步

先确认本机环境变量存在，但不要把 token 打印出来：

```powershell
@{
  NOTION_API_KEY_Configured = [bool]$env:NOTION_API_KEY
  NOTION_DATA_SOURCE_ID_Configured = [bool]$env:NOTION_DATA_SOURCE_ID
}
```

然后执行一次同步：

```powershell
npm.cmd run collect
npm.cmd run build
```

检查 `state/data.json` 中的 `todo.source` 是否为 `notion`，以及 `todo.items` 是否只包含预期的前三条。Notion 暂时不可用时，程序会保留上一份有效数据，避免 Kindle 直接显示为空或离线。

## 5. 用 ChatGPT / Codex 管理待办

项目同时提供了本机 Codex 技能 `kindle-todo`。它的工作规则是：

1. 从自然语言识别任务、截止时间、优先级和是否显示到 Kindle。
2. 创建、修改或标记完成前先向你确认。
3. 将确认后的操作写入 Notion；Notion 是唯一事实来源。
4. 由电脑定时任务采集，GitHub Pages 发布公开快照，Kindle 定时读取。

可以这样使用：

```text
使用 $kindle-todo，把“明天下午提醒我检查 Kindle 插件，优先级高”整理成待办。
```

技能只负责识别和编排操作，不会绕过确认自动删除或完成任务，也不会把 Notion token 写入项目。

## 6. 隐私边界

GitHub Pages 默认公开。不要勾选包含密码、客户信息、案件信息或其他敏感内容的任务。公开快照只应包含 Kindle 必须显示的标题、截止标签和优先级。
