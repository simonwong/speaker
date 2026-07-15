# 验证本机 Fn、输入目标与文本送达

Type: prototype
Status: open
Blocked by: 01

## Question

在用户当前 macOS 与键盘上，默认 `Fn` 和候选自定义组合键能否稳定产生按下/松开边沿；松开后捕获的输入目标能否在模型等待后向 TextEdit、Safari、Chrome/Electron 等代表性控件安全送达文本？需要用 throwaway Swift 原型记录已验证支持矩阵、权限体验、Secure Input、并发编辑和目标失效行为，以决定正式实现保留哪些送达适配器、哪些场景直接产生待复制结果。
