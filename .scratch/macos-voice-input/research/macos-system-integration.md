# macOS 全局按键与文本送达边界

研究日期：2026-07-15

## 结论

这套 MVP 在非沙盒、本机运行的 macOS App 中可实现，但要把“能够尝试送达”和“保证写回松开时的同一编辑位置”分开：

- `Fn` 是修饰键状态，不是普通字符键。使用 session 级 `CGEventTap` 监听 `flagsChanged`，并比较 `CGEventFlags.maskSecondaryFn` 的前后状态，可以得到按下与松开。Apple 明确定义该 flag 表示 Fn 按下；event tap 能监听按键按下和释放，但跨 App 键盘监听需要用户授权。[`maskSecondaryFn`](https://developer.apple.com/documentation/coregraphics/cgeventflags/masksecondaryfn)、[CGEventTapCreate](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate%28tap%3Aplace%3Aoptions%3Aeventsofinterest%3Acallback%3Auserinfo%3A%29)、[WWDC19: Advances in macOS Security](https://developer.apple.com/videos/play/wwdc2019/701/)
- 普通自定义组合键可以使用 `RegisterEventHotKey` 注册，并接收 `kEventHotKeyPressed` 与 `kEventHotKeyReleased`。当前 macOS SDK 仍提供这些 API，且没有标记 deprecated；注册是否成功必须作为运行时结果处理，不能只靠静态冲突表。
- 松开时可通过 system-wide AX 元素取得当前接受键盘输入的 App，再取得它的 `kAXFocusedUIElementAttribute`；可编辑元素应提供选择范围，但第三方 App 可以不完整实现 Accessibility，调用也可能返回 invalid、unsupported、cannot complete 或 not implemented。[`kAXFocusedApplicationAttribute`](https://developer.apple.com/documentation/applicationservices/kaxfocusedapplicationattribute)、[`kAXFocusedUIElementAttribute`](https://developer.apple.com/documentation/applicationservices/kaxfocuseduielementattribute)、[`AXUIElement.h`](https://developer.apple.com/documentation/applicationservices/axuielement_h)
- `AXUIElementRef` 可以作为 Core Foundation 对象保留，但 Apple 没有承诺它在控件销毁、页面重载、窗口关闭或进程退出后仍有效；稍后访问必须重新验证，`kAXErrorInvalidUIElement` 就是这种失效的正式错误之一。[`AXUIElement.h`](https://developer.apple.com/documentation/applicationservices/axuielement_h)
- Apple 没有提供一个适用于所有 App 的“向任意旧 AX 编辑位置插入字符串”原子 API。AX 提供读取、属性可写性探测和设值；选择范围按契约可写，但不同文本属性、富文本和第三方控件的写入支持不同。因此，“用户已经切走后仍写回旧位置”只能按能力尝试，不能作为全 App 保证。[`AXUIElementIsAttributeSettable`](https://developer.apple.com/documentation/applicationservices/1459972-axuielementisattributesettable)、[`AXUIElementSetAttributeValue`](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)、[`kAXSelectedTextRangeAttribute`](https://developer.apple.com/documentation/applicationservices/kaxselectedtextrangeattribute)
- MVP 需要 Accessibility 和 Microphone 两项用户授权。因为 Accessibility 已覆盖事件监听、事件发送和跨 App AX 控制，不应再额外要求 Input Monitoring；Apple DTS 明确说明 Accessibility 同时授予 listen 和 post，而 Input Monitoring 只授予 listen。[Apple DTS 对权限边界的说明](https://developer.apple.com/forums/thread/828052)
- MVP 必须关闭 App Sandbox。Apple 明确把 assistive app 使用 Accessibility API 列为与 App Sandbox 不兼容的活动；这与本项目只保证本机 Xcode 构建、不上 Mac App Store 的范围一致。[Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- 安全输入必须 fail closed：检测到系统 Secure Event Input，或输入目标的 AX subrole 是 `AXSecureTextField`，均不得自动写入。Secure Event Input 会阻止其他 App 的事件监控；安全文本框还可能不暴露真实值。该行为由当前 Apple SDK 的 `CarbonEventsCore.h` 定义；安全控件类型见 [`kAXSecureTextFieldSubrole`](https://developer.apple.com/documentation/applicationservices/kaxsecuretextfieldsubrole) 和 [NSSecureTextField](https://developer.apple.com/documentation/appkit/nssecuretextfield)。

其中 Secure Event Input 的线上链接没有独立展示 Carbon 头文件说明；本研究同时核对了当前 Apple macOS SDK 的 `Carbon.framework/.../CarbonEventsCore.h`：启用后，键盘输入只发送给聚焦 App，不再复制给其他 App 的 event monitor；`IsSecureEventInputEnabled()` 返回任意进程是否启用该模式。

## 建议的 MVP 系统集成契约

### 1. 全局按键层

默认 `Fn`：

1. 创建 `.cgSessionEventTap`、`.listenOnly` 的 `CGEventTap`，至少监听 `flagsChanged`；若 `Esc` 用于取消，还需监听相应 key down。
2. 对每次 flag change 比较 `maskSecondaryFn`：`false -> true` 开始录音，`true -> false` 结束录音。
3. event-tap callback 只更新极少状态并立即转交工作队列，不在 callback 里做 AX IPC、停止编码或网络请求。Apple 会在 tap 无响应时禁用它，并通过 disabled 事件通知；App 要能调用 `CGEventTapEnable` 恢复并显示状态。[`CGEventTapEnable`](https://developer.apple.com/documentation/coregraphics/cgevent/tapenable%28tap%3Aenable%3A%29)、[`kCGEventTapDisabledByTimeout`](https://developer.apple.com/documentation/coregraphics/cgeventtype/tapdisabledbytimeout)
4. 用状态机去重 `flagsChanged`，避免把重复 flag 事件当成第二次开始或结束。

`Fn` 本身不能用 `RegisterEventHotKey` 注册，因为该 API 要求一个主 virtual key code 加 modifiers，而 `Fn` 在这里本身是 modifier。它也无法像普通 exclusive hotkey 那样可靠占用，所以系统对 Fn/Globe 的配置仍可能同时触发。macOS Keyboard 设置允许 Fn/Globe 执行“切换输入源”“显示 Emoji 与符号”“开始听写”或“无操作”；若出现冲突，引导用户设为“无操作”或改用自定义快捷键。[Keyboard settings on Mac](https://support.apple.com/en-asia/guide/mac-help/kbdm162/mac)

外接键盘边界：Apple 只把 `maskSecondaryFn` 描述为主要存在于笔记本键盘的 Fn 状态，未承诺所有第三方键盘都会把硬件 Fn 键上报给 macOS。因此默认 Fn 需要在内建键盘和目标外接键盘上实测；检测不到时必须让用户改快捷键。

自定义快捷键：

- 对“修饰键 + 主键”优先用 `RegisterEventHotKey`，监听 pressed/released，并申请 exclusive registration；保存设置前必须真实注册一次，失败即拒绝保存或恢复旧快捷键。
- 不允许用户只录入纯修饰键作为普通自定义快捷键；`Fn` 是产品单独支持的特殊项。
- 避免默认占用 Apple 标准快捷键。Apple HIG 要求尊重标准快捷键，系统也明确提醒冲突组合可能不工作。[Keyboards HIG](https://developer.apple.com/design/human-interface-guidelines/keyboards/)、[Change a conflicting keyboard shortcut](https://support.apple.com/en-au/guide/mac-help/mchlp2864/mac)
- macOS 15.0/15.1 曾限制仅 Option/Shift 的 hotkey 注册；Apple Frameworks Engineer 表示该问题在 15.2 beta 2 修复。仍应以运行时注册结果为准，而不是假定所有版本行为一致。[Apple Frameworks Engineer 的说明](https://developer.apple.com/forums/thread/763878)

### 2. 松开时捕获输入目标

“输入目标”需要保存的不是 App 名称，而是一次短生命周期快照：

- `AXUIElementRef`：松开后第一次 AX 查询得到的聚焦元素；
- 目标 PID、bundle identifier 和可读 App 名称；
- AX role、subrole；
- `kAXSelectedTextRangeAttribute`，即松开时的光标或选区；
- 用于防止错写的内容版本证据，例如当时的 `kAXValueAttribute` 或其仅存于内存的摘要；不要把被编辑内容额外写入历史；
- 捕获结果和具体 AX error。

捕获顺序应为：从 system-wide element 取得 `kAXFocusedApplicationAttribute`，再向该 application element 请求 `kAXFocusedUIElementAttribute`。Apple 对前者的说明就是“先快速确定接受键盘输入的 App，再向该 App 请求 focused accessibility object”。[`kAXFocusedApplicationAttribute`](https://developer.apple.com/documentation/applicationservices/kaxfocusedapplicationattribute)

严格意义上的“松开瞬间”无法由异步 App 做跨进程原子快照。event tap callback 不能阻塞，而 AX 查询是可失败、可超时的 IPC。因此规格应定义为“收到 Fn 松开事件后立即发起的第一次成功 AX 查询”；悬浮层不能激活 App 或抢焦点，并且必须在该查询之后显示。

如果松开时没有 focused application、没有 focused UI element、目标不是可编辑元素、AX 查询超时或目标是安全输入框，本次输入目标即为空。完成转录后进入待复制结果。

### 3. 稍后送达的保守阶梯

送达前必须重新检查：Accessibility 仍获授权、PID 仍存在、AX element 仍有效、不是 secure subrole、目标支持预期属性、内容没有在网络等待期间发生无法解释的变化。

建议只按以下阶梯尝试：

1. **已验证的直接 AX 插入适配器**：运行时确认相应文本属性 settable，并且该 App/控件类型已通过“替换选区、光标插入、中文、emoji、多行、撤销”测试，才向保留的 AX element 写入。不能把某个控件成功泛化成所有 App。
2. **目标仍是当前聚焦元素**：若内容版本未变化，可恢复松开时的 `kAXSelectedTextRangeAttribute`，再向目标 PID 发送带 Unicode string 的键盘事件。Core Graphics 支持创建 keyboard event、设置其 Unicode string，并用 `CGEventPostToPid` 发送到特定进程；但事件最终仍由该进程当前键盘目标处理，所以必须先确认当前 focused AX element 与快照相同。[`CGEvent`](https://developer.apple.com/documentation/coregraphics/cgevent)、[`CGEventCreateKeyboardEvent`](https://developer.apple.com/documentation/coregraphics/cgevent/init%28keyboardeventsource%3Avirtualkey%3Akeydown%3A%29)
3. **否则不写**：进入待复制结果，不激活旧 App、不改变旧 App 的焦点、不模拟 `Command-V`，也不自动改剪贴板。

不推荐把“整段读取 `AXValue`、字符串拼接、整段回写”作为通用方案。虽然 `AXValue` 可能可写，但对富文本、超长文档、受校验字段和自定义编辑器可能丢失格式、绕过正常编辑语义或覆盖并发修改。它最多是针对简单 `AXTextField`、经过实测的单独适配器。

也不推荐后台强制设置旧元素的 `kAXFocusedAttribute = true` 后发键盘事件。Apple 确认 focus 属性对可聚焦元素可写，但这样会改变用户当前工作状态，而且事件送到哪个内部编辑对象仍取决于目标 App 的实现。[`kAXFocusedAttribute`](https://developer.apple.com/documentation/applicationservices/kaxfocusedattribute)

### 4. Secure Input 与安全字段

需要两道独立防线：

- 热键层调用 `IsSecureEventInputEnabled()`。为 true 时不启动新录音；若录音期间变为 true，应取消录音，并以最大录音时长 watchdog 防止 Fn release 被 Secure Input 屏蔽后永久录音。
- 目标层读取 `kAXSubroleAttribute`。等于 `kAXSecureTextFieldSubrole` 时，禁止自动写入。

`IsSecureEventInputEnabled()` 是全局信号，不告诉调用方哪个 App 开启了它；而自定义 Web/跨平台密码控件也不一定正确暴露 secure subrole。因此两者只能提高安全性，不能证明任意目标“不是密码框”。对于未知、不可读或不完整 AX 控件，MVP 应选择待复制，而不是乐观写入。

后续数据策略还需要决定：安全字段触发的会话是否进入历史。系统研究只能确定“不自动送达”；从最小泄露原则看，建议此类会话也不持久化转录文本。

## 权限与沙盒

### Accessibility

调用 `AXIsProcessTrustedWithOptions` 检查并可异步提示用户授权。Apple 明确说明这个函数只报告当前进程是否为 trusted accessibility client；提示不会改变本次返回值，因此授权引导必须可恢复，用户回到 App 后重新检查。[`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)

本 MVP 需要它完成三件事：跨 App 读取 focused element、设置 AX 属性、监听/发送键盘事件。Apple DTS 说明 Accessibility 已同时包含 listen 和 post，所以不再单独请求 Input Monitoring，避免让用户看到两个相似权限。

### Microphone

macOS 10.14 及以后，App 必须在 `Info.plist` 提供 `NSMicrophoneUsageDescription`，并通过 AVFoundation 请求 audio capture access；系统设置允许用户随时撤销。[Requesting Authorization for Media Capture on macOS](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos)、[Control access to the microphone on Mac](https://support.apple.com/en-ie/guide/mac-help/mchla1b1e1fe/mac)

MVP 不启用 App Sandbox，所以不需要 sandbox 的 `com.apple.security.device.microphone` 与 `com.apple.security.network.client` entitlement；TCC 麦克风授权仍然需要。若将来启用 sandbox，麦克风和网络 entitlement 虽可添加，但 assistive AX 控制仍与 sandbox 冲突，不能据此直接转成 Mac App Store 架构。

### Input Monitoring

如果某个将来的沙盒版本只做被动 CGEventTap，不再控制其他 App，Apple DTS 给出的路径是 Input Monitoring，并可用 `CGPreflightListenEventAccess` / `CGRequestListenEventAccess`；Apple 也说明该权限允许 App 在用户使用其他 App 时监控键盘、鼠标或触控板。[Apple DTS 的 sandbox event tap 说明](https://developer.apple.com/forums/thread/707680)、[Control access to input monitoring on Mac](https://support.apple.com/en-gb/guide/mac-help/mchl4cedafb6/mac)

这不是当前 MVP 的权限方案，因为当前 MVP 已因 AX 送达需要更广的 Accessibility 权限。

## 不同 App 的兼容性边界

| 目标类型 | Apple 一手资料能确认什么 | MVP 结论 |
| --- | --- | --- |
| 标准 AppKit / SwiftUI 文本控件 | 标准 AppKit 控件带内置 accessibility；editable text element 应提供 selected text range | 首要支持对象，但仍按属性可写性探测；TextEdit 必须进验收矩阵 |
| Safari / WebKit 的普通 input、textarea、contenteditable | macOS SDK 定义了 Web accessibility 属性，但 Apple 没有承诺所有 Web 编辑器都支持同一种 AX 写入 | Safari 三类控件分别实测；失败即待复制 |
| Chromium / Electron | 不属于 Apple 控件契约，Apple 资料无法替其保证 AX 实现 | Chrome、VS Code 或目标 Electron App 作为独立测试类，不作先验保证 |
| 富文本编辑器（Notes、富文本 TextEdit 等） | AX 可暴露 range/attributed-string 相关属性，但没有统一 insertion action | 禁止通用整段 `AXValue` 回写；只用已验证路径 |
| Terminal、IDE、自绘或游戏式编辑器 | 第三方进程可能返回 `kAXErrorNotImplemented`、unsupported 或 cannot complete | 独立测试；默认待复制 |
| 密码与安全字段 | 有 `AXSecureTextField` subrole；Secure Event Input 可阻断监控 | 永不自动写入 |
| iPhone/iPad App on Apple silicon | macOS 可运行这些 App，但其桥接后的 AX 与文本事件行为不是本研究资料中的保证 | MVP 不承诺，后续实测 |

Apple 明确建议自定义控件实现 accessibility，并指出标准 AppKit 控件已经采用相关协议；这同时意味着自定义控件的完整性取决于目标 App 开发者。[Integrating accessibility into your app](https://developer.apple.com/documentation/accessibility/integrating-accessibility-into-your-app)

## 最低 macOS 版本建议

系统集成本身不要求新版本：`AXIsProcessTrustedWithOptions` 从 macOS 10.9 可用，`CGEventPostToPid` 从 10.11 可用，`CGPreflightListenEventAccess` / `CGRequestListenEventAccess` 从 10.15 可用；其余核心 AX、event tap 和 Carbon hotkey API 更早已存在。若只看本票，macOS 10.15 是覆盖完整现代权限预检 API 的技术下限。

但这个产品只要求在用户本机运行，且还要使用现代 SwiftUI 菜单栏、历史存储和 Swift 6。建议规格把 MVP deployment target 暂定为 **macOS 14.0**，原因是缩小测试矩阵并给后续 SwiftData 等现代实现留空间，而不是系统集成 API 强迫。最终票如果不用 macOS 14+ API，可以再降；本票不支持把最低版本抬到当前机器的 macOS 26。

## 必须通过原型或真机测试才能锁定的事项

以下内容没有 Apple 跨 App 契约，不能仅靠文档研究宣称完成：

1. 当前用户内建键盘和外接键盘的 Fn/Globe 是否都产生预期 `flagsChanged`。
2. Fn 设置为切换输入源、Emoji、听写、无操作时，按住/松开的实际冲突表现。
3. `RegisterEventHotKey` 在目标 macOS 版本对候选组合的 pressed/released、exclusive 和冲突返回值。
4. 标准 `NSTextField`、`NSTextView` 中 `AXSelectedText` 的可写性及设置语义。
5. TextEdit、Notes、Safari input/textarea/contenteditable、Chrome、VS Code/Electron、Terminal 的目标捕获、选择替换、中文/emoji、多行、撤销和后台切换行为。
6. 用户在模型请求期间编辑原文本、移动光标、关闭窗口、刷新网页、退出目标 App 时是否全部正确降级。
7. Secure Input 已开启时 Fn down/release、Esc 和 watchdog 的行为。

建议把 1–7 做成一次 throwaway Swift 原型，而不是在正式 App 中边写边猜。测试结论应成为最终实现规格中的“支持矩阵”，并且按 App 家族写明 verified 或 fallback，不使用“所有 macOS 输入框均支持”这样的表述。

## 直接影响后续票的决策

- 会话状态机必须存在 `noTarget`、`targetInvalidated`、`targetChanged`、`targetUnsupported`、`secureInput`、`accessibilityDenied`、`deliveryFailed` 与 `pendingCopy`，不能只有 success/failure。
- 输入目标快照只在内存中活到会话终止；不得把 `AXUIElementRef` 或目标原内容持久化。
- 历史记录可保存目标 App 名称、bundle identifier、最终送达状态和 AX error 分类，但不能保存为验证并发修改而读取的目标原文本。
- 悬浮层必须 non-activating；捕获目标完成前不得打开设置、历史或任何可能抢焦点的窗口。
- “已发送”只能在可验证的 AX/事件调用成功后记录。无法确认时记录为待复制，不做乐观成功。
- 正式规格的兼容性承诺应是“能力探测 + 已验证支持矩阵 + 待复制兜底”，不是“任意 App 直接写入”。

## 第一方资料

- [CGEventTapCreate](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate%28tap%3Aplace%3Aoptions%3Aeventsofinterest%3Acallback%3Auserinfo%3A%29)
- [CGEvent / event posting](https://developer.apple.com/documentation/coregraphics/cgevent)
- [NSEvent global monitor](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29)
- [AXUIElement.h overview and error contract](https://developer.apple.com/documentation/applicationservices/axuielement_h)
- [AXUIElementSetAttributeValue](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)
- [Accessibility attributes](https://developer.apple.com/documentation/applicationservices/carbon_accessibility/attributes)
- [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [WWDC19: Advances in macOS Security](https://developer.apple.com/videos/play/wwdc2019/701/)
- [Apple DTS: Accessibility vs Input Monitoring](https://developer.apple.com/forums/thread/828052)
- [Apple DTS: sandboxed passive event tap](https://developer.apple.com/forums/thread/707680)
- 当前本机 Apple SDK headers：`AXUIElement.h`、`AXAttributeConstants.h`、`AXRoleConstants.h`、`CarbonEventsCore.h`、`CarbonEvents.h`、`CGEvent.h`、`CGEventTypes.h`。
