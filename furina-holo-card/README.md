# 芙宁娜 · 水色舞台全息卡

基于本地芙宁娜参考图制作的原创同人收藏卡。拖动卡牌改变角度，滚轮缩放，点击翻面；可调整人物、水纹及背景的景深，并切换珠光、银箔、烫金和原画。

## 打开网页
双击“打开全息卡.cmd”。安装有 Node.js 的其他电脑也可在 web 目录运行 `node server.mjs`，然后打开 http://127.0.0.1:4173 。无需 npm 安装；浏览器须支持 WebGL。

## 可编辑文件
- assets：人物、剧院背景、真实轮廓线、字体排版与水纹五个独立图层。
- card-config.json：名称、卡文、景深及光泽参数。
- web：Three.js 模型、GLSL 全息材质及完整网页源码，含预构建 bundle。
- card.blend：Blender 可编辑材质节点与卡牌场景。
- renders：预览和网页导出 PNG。
- verification：浏览器检查报告及实拍截图。

网页使用 GLSL 重建 Blender 的材质逻辑，两者效果并非逐像素一致。系统开启“减少动态效果”时默认静止，仍可手动拖动与翻面。

本项目为非官方同人作品。角色设计归原权利人；本地参考图片不包含在交付压缩包中。

## 重新构建 Blender
可使用 Blender 4.5 LTS 运行 `blender --background --python scripts/build_card.py -- .`。也可在 Python 3.11 中安装官方 `bpy==4.5.3` 后运行 `python scripts/build_with_bpy.py`。重新导出网页实体网格：`blender --background --python scripts/export_web.py -- .`。
