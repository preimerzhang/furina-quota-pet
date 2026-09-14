# 芙宁娜桌面宠物

使用已制作的芙宁娜动画图集，提供 Windows 桌面宠物与 Codex 账号额度查看功能。

![芙宁娜](furina-pet/芙宁娜.png)

## 启动

下载或克隆仓库后，双击 `furina-pet/desktop/启动芙宁娜.cmd`。需要 Windows、Python 3，以及已安装并使用 ChatGPT 账号登录的 Codex 桌面应用。

- 单击宠物，实时显示当前账号剩余额度、重置时间与更新时间。
- 按住拖动移动窗口；鼠标靠近时，宠物会转动视线。
- 双击随机挥手或跳跃，显示可关闭的角色风格短语。
- 自动记住位置与大小；右键设置调整大小、互动频率、视线和全屏隐藏。
- 托盘及 Ctrl+Alt+F10 控制显示或隐藏；可在设置中开启登录 Windows 后自动启动，默认关闭。
- 可关闭的低额度提醒，支持阈值设置及按重置周期去重。
- 番茄钟、暂停与休息提醒，专注期间安静陪伴。
- 显示器选择、边缘吸附及断开显示器后的位置恢复。
- 右键查看额度、关闭面板或退出；面板支持 × 和 Esc。

读取额度使用官方 app-server 的 `account/rateLimits/read`，不会重置额度或购买信用。账号凭据由 Codex 自身管理，项目不包含凭据。详见 [桌面版说明](furina-pet/desktop/README.md)。

## 素材

图集包含 9 组动画与 16 个视线方向。独立窗口的动画由自身交互驱动；`furina-pet/furina` 同时保留 Codex v2 宠物素材包。角色造型与动作依据见 [设计记录](furina-pet/character-notes.md)。

原始参考图片、生成中间文件、运行日志、缓存和本机辅助工具保留在本地，未纳入版本控制。

## 验证

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\furina-pet\desktop\furina.ps1 -SmokeTest
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\furina-pet\desktop\furina.ps1 -IntegrationTest
```

第二项需要可用的 Codex 登录与网络，验证拖动不查询、单击查询并显示真实额度。

本项目为角色同人桌面宠物，与游戏官方无关联。角色相关权利归其权利人；仓库暂未指定开源许可证。
