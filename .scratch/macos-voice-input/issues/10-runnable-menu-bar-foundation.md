# 10 — 建立可运行的菜单栏基础

**What to build:** 一个能从命令行构建、测试并启动的 macOS 14 菜单栏 App，显示服务与权限状态，可打开设置和会话历史空态，为后续纵切片提供稳定运行入口。

**Blocked by:** None — can start immediately

**Status:** done

- [x] Swift package 能用仓库提供的统一命令构建与运行，并在当前 SDK/compiler 环境选择兼容 SDK 和可写 module cache
- [x] App 以菜单栏形态启动且默认不显示 Dock 图标
- [x] 菜单能打开设置、会话历史空态、权限状态并退出
- [x] 设置能显示 Accessibility 与 Microphone 的当前状态并触发系统授权流程
- [x] 测试从约定的高层 seam 启动，完整测试命令通过
