# 16 — 加固本机运行与系统兼容性

**What to build:** 在用户当前 Mac 上完成可重复构建、App bundle 启动、登录启动选项、权限恢复和代表性目标兼容性验证，明确哪些 App 自动送达、哪些稳定降级为待复制结果。

**Blocked by:** 11 — 打通本机按住说话 tracer

**Status:** in-progress

- [ ] 统一脚本可以测试、构建、组装并启动带正确 Info.plist 的本地 App bundle
- [ ] 登录时启动默认关闭，可由设置开启和关闭，并准确反映系统状态
- [ ] event tap timeout、权限撤销、Secure Event Input、App 退出和网络任务清理均可恢复
- [ ] 本机验证内建/可用外接键盘 Fn、候选自定义快捷键和系统 Fn/Globe 冲突提示
- [ ] 支持矩阵覆盖 TextEdit、Safari 可用控件、Chrome/Electron 代表、富文本、Terminal、安全字段、焦点切换、目标关闭、并发编辑、Unicode、emoji、多行、选择替换和撤销
- [ ] 未验证或失败场景统一待复制，不通过模拟粘贴、强制焦点或整段 AXValue 回写扩大表面成功率
- [ ] 命令行完整测试、构建与本地 smoke launch 通过
