# KOReader 版 AI 额度中控台

这个版本不启动 Kindle 浏览器。它是一个 KOReader 插件，通过 Wi-Fi 请求 GitHub Pages 上的 `data.json`，然后使用 KOReader 的原生界面显示额度。

## 安装到 KPW1

1. 确认 KPW1 已安装 KUAL 和 KOReader。
2. 通过 USB 打开 Kindle 根目录。
3. 将 `aiquota.koplugin` 整个文件夹复制到：

   `koreader/plugins/aiquota.koplugin/`

4. 安全弹出 Kindle，启动 KOReader。
5. 打开 KOReader 菜单 → More tools，点击 `AI quota dashboard`。

KPW1 使用 KOReader 的 `kindle` 架构包，不要使用 `kindlepw2` 包。本插件本身只依赖 KOReader 的 Lua 网络和界面模块。

## 使用

插件每次打开时请求最新数据。KPW1 需要先连接 Wi-Fi；这不是 Kindle 浏览器访问，而是 KOReader 插件的网络请求。

如果没有网络，插件会显示请求失败，不会修改 Kindle 系统界面。
