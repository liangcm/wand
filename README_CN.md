[English](README.md)

# Wand

把 Apple Siri Remote 变成 Mac 的控制器。

Wand 是一个 macOS 菜单栏应用:配对你手上已有的 Siri Remote,把它的每一种输入——触控板、按键、手势——映射成 Mac 上真正有用的操作:移动光标、点击、滚动、发送键盘快捷键、输入命令、打开应用。

> **实验性质。** Wand 建立在两个逆向工程的私有接口之上(私有 `MultitouchSupport` 框架 + HID 层事件截获),Apple 随时可能改动。请对小问题有心理预期。

## 功能

**触控板**
- 单指滑动移动光标;双指滑动滚动页面
- 轻触点击(可在面板中关闭——关闭后仅物理按压触发点击,防误触)
- 中心按压 = 鼠标点击,支持按住拖拽
- 边缘方向点击(上/下/左/右)朝对应方向推动光标——步长由「鼠标灵敏度」滑块调节
- 四个滑动手势方向,均可映射任意动作
- 多指捏合调出配置面板

**按键**
- 每个实体按键均可映射,单击与双击可分别绑定
- 动作分三类 + 特殊功能:
  - **功能键** —— Enter、Tab、Space、Backspace、Delete、Esc、方向键、左右修饰键、Fn、鼠标左键/右键
  - **F 键** —— F1–F12
  - **组合键** —— Cmd+C/V/X/Z/Shift+Z/A/S/W/F、Ctrl+C、Shift+Tab,或按一下即可**学习**任意自定义快捷键
  - **特殊功能** —— 输入任意文本或斜杠命令(可选追加空格/Enter),或打开指定应用

**面板与系统**
- 可视化配置面板:点击遥控器示意图上的任意控件,直接选映射
- 双语界面(简体中文 / English),跟随系统语言;适配深色/浅色模式
- HID 抢占:Wand 运行时,macOS 不再重复响应遥控器的媒体键
- 音量回退保护:遥控器按键引发的蓝牙 AVRCP 系统音量变化会被自动回退,只保留你映射的动作

**支持的遥控器:** Siri Remote 一代(A1513/A1962)、二代(A2540)、三代(A2854)。

## 安装

1. 从 [Releases](https://github.com/wongsiufool/wand/releases) 下载公证版 DMG,把 **Wand.app** 拖入「应用程序」(或自行构建,见下文)
2. 启动 Wand——菜单栏出现遥控器形状的图标
3. 在**系统设置 → 隐私与安全性**中授权:
   - **辅助功能** —— 合成键盘/鼠标事件所需
   - **输入监控** —— 截获遥控器媒体键所需
4. 通过蓝牙将 Siri Remote 与 Mac 配对
5. 打开**菜单栏图标 → 打开遥控器面板…**配置映射

诊断日志写入 `/tmp/wand.log`。

## 构建

```bash
./build.sh                # 编译（链接私有 MultitouchSupport 框架）
./create_app_bundle.sh    # 打包 + ad-hoc 签名 Wand.app
./create_dmg.sh           # 完整分发包：Developer ID 签名 + DMG
NOTARY_PROFILE=<profile> ./create_dmg.sh   # + 公证与钉票据（正式发布）
```

`create_dmg.sh` 会自动探测钥匙串中的 Developer ID 证书,没有则降级为 ad-hoc 签名并给出警告。公证凭据的一次性配置见脚本头部注释。

> 提示:ad-hoc 签名将 TCC 权限绑定到二进制哈希,重新编译后需在系统设置中重新授权。

## 渊源

Wand 的前身是 **Mavrick**——本项目的旧名,也是核心思路的来源:在 HID 层抢占 Siri Remote、通过私有多点触控接口驱动光标、把遥控器输入映射为桌面操作。

Mavrick 本身基于 [Jinsoo An (machinarii)](https://github.com/machinarii) 的 [HyperVibe](https://github.com/machinarii/hypervibe)(MIT License)二次开发,HyperVibe 又基于 [@lauschue](https://github.com/lauschue) 的 [Remotastic](https://github.com/lauschue/Remotastic)。Remotastic 提供了 Siri Remote HID 处理、MultitouchSupport 集成和菜单栏框架;HyperVibe 在此基础上增加了可配置工作流、键盘快捷键与手势支持。光标边缘贴合与拖拽优化合并自 HyperVibe PR #1,感谢 [@ChestnutLUO](https://github.com/ChestnutLUO)。

## 许可

MIT —— 见 [LICENSE](LICENSE)。
