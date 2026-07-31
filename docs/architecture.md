# 架构

```text
本机采集器
  ├─ DeepSeek：环境变量中的 API 密钥
  ├─ Claude：可选读取本机 Claude Code 登录文件
  ├─ Codex：可选启动本机 codex app-server
  ├─ Kimi：可选只读本机 Kimi Code 登录文件
  ├─ Weather：Open-Meteo 当前天气与 12 小时预报
  └─ TO DO：本地文件或 Notion Data Source
          │
          ▼
      state/data.json + state/data.js
          │
          ├─ 局域网静态服务器
          └─ 用户自己的静态托管或 GitHub Pages
                      │
                      ▼
              KOReader 插件每 5 分钟取一次 data.json
```

## 设计原则

- 采集与展示分离：页面永远只接触脱敏后的快照，不接触令牌。
- 默认拒绝读取本机登录文件：Claude、Kimi 必须由用户双重显式开启。
- 单源失败隔离：一个服务失效时，其余卡片继续更新。
- 最后成功值兜底：已启用的采集器临时失败时，保留上一次成功结果并标记“旧值”。
- 真实运行数据不进入源码仓库：`state/`、`dist/` 和 `history/` 默认忽略。

## 部署节奏

采集频率、静态托管同步频率和 Kindle 插件刷新频率是三层独立设置。插件默认每
5 分钟检查一次，低电量时自动调整为每 15 分钟；实际新鲜度还取决于用户多久运行
一次采集与部署。
