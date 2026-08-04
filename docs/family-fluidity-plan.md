# Family-style Tray & Fluidity Plan

对照 [Family Values](https://benji.org/family-values)(Benji Taylor, 2024)的 tray 系统与流动性理念,
把 Dash 现有的 tray / 动效体系补齐到同等体验。共 6 个工作项(P1–P6)+ 2 条内容编辑纪律,
按依赖与风险排序,每项可独立落地、独立验收。

**总原则(来自 AGENTS.md,不可违反):**

- 保持公开 `dashTray` API 与 modal host 不动;不引入 large/expanded tray、detent、root overlay。
- 不做 tray→全屏 morph;需要升级为全屏时,用「tray 收起 + 立即 push,共享同一标题文案」近似。
- 不动 tab pager:原生 page 滑动已提供方向性;top wash 架构不许再叠动画。
- 不用 iOS 18 `navigationTransition(.zoom)`(目标 iOS 17+,且会和 avatar→back 的 header crossfade 打架)。
- 所有新动效必须带 Reduce Motion 分支(惯例:保留 opacity,去掉位移/缩放)。
- 新增用户可见文案一律走 `Localizable.xcstrings`(五个 bundle 共享),`pnpm lint:l10n` 必须过。
- 收尾时把新规则(✕→←、方向性步进、tone、高度纪律)写回 AGENTS.md 的 tray 段落。

**进度:** P1 ✅ P2 ✅ P3 ✅(P3 补充:submit pill 标签走 `FeatureVisualTone.vividLabel`,
`.accent` 因中等明度固定近黑墨;非 destructive header 圈的 tone 分支暂无生产调用点,
启用前需真机验证 12% tint 上的图标对比度)。P4 ✅(实现补充:morph 采用两阶段提交 ——
先无动画按新 diff 边界重切旧文案再溶解变化段,避免连续 morph 时共享字符短暂重复;
`DashActionButton` 新增可选 `labelMorphID`,危险行 → 确认 pill 与 Profile Sign out
两个端点的文字层现在随 matched-geometry 表面一起移动;`DashLoadMoreFooter` 的
"Showing X of Y" 补了 `.numericText`)。P5 ✅(实现补充:anchor 走
`DashTraySourceRegistry`(@MainActor,frames 非追踪、仅 `occupiedID` 可观察)+
`DashTrayAnchorMath` 整卡 rect→rect 变换;首批接入是 Home Quick actions 的全部
tile(以 accessibility identifier 为稳定 sourceID),不止计划里的三个;Add Domain
因 Domains 区块共用同一 tray 保持不 anchor;呈现时冻结源 frame,✕ 关闭且已 settle 时
重读一次当前 frame 再收回;卡片 rect 由布局纯推导(容器 global frame + fitted 高度
preference + 边距/底距),绝不经 reveal transform 测量,消除几何回读的时序依赖;
入场未 settle 时任何关闭(✕/拖拽/scrim/程序化)都保持 anchor 从当前姿态连续反向收回,
两个 reveal modifier 只在 settled progress 1 处交接)。P6 ✅(实现补充:实例改为 **R2 Create bucket** 而非 Purge
Cache —— Purge Cache 实际是 pick-zone 后 push 页面,没有 submit-成功-收起的时序;
Create bucket 的 成功勾 → success toast leading mark 贝塞尔弧线由
`DashTrayFlightMath` 驱动,落点按 toast ID 绑定(`dashTraySuccessFlightTarget`,
`DashToastCenter.success` 返回新 toast 的 ID),飞行勾沿弧线做 pill 墨色 → toast
绿的双层 crossfade;`dashTraySuccessFlight()` 为唯一生产 opt-in,架构脚本守卫单实例)。

---

## P1 — DashTrayFlow 路由栈 + ✕→← morph

**Family 规则:** tray 序列中,首个 tray 的图标是 ✕(dismiss),后续 tray 同一个图标变成 ←(逐级返回)。

**现状:**

- `DashTrayFlow<Route, Content>`(`DashChrome.swift` ~L293)只接收单个 `route` 值,无历史概念。
- `DashSheetMenuButtons`(~L368)永远渲染 `DashCloseButton { dismiss() }`,无 back 分支。
- 各调用点自己在 footer 放 Cancel 实现返回:
  - `ProfileSettingsViews.swift` ~L103–161(accounts → 切换/登出确认,`phase = .accounts`)
  - `HomeView.swift` ~L1896–1953(Add domain:`.form` / `.created(String)`)
  - `StorageViews.swift` ~L492–613(R2:`.menu` / `.createFolder` / `.deleteFolder`)

**设计:**

1. 新增带栈语义的 `DashTrayFlow` overload,旧的单 route overload 保留(向后兼容):

   ```swift
   DashTrayFlow(root: Route, path: Binding<[Route]>, role: (Route) -> DashTrayStepRole) { route in … }
   ```

   活跃 route = `path.last ?? root`。`pop()` = `path.removeLast()`。

2. 新增 PreferenceKey(与 `DashTrayStepRoleKey` 同款上报路径)把「可返回」状态送进 header:

   ```swift
   struct DashTrayBackAction: Equatable { let depth: Int; let perform: () -> Void }  // Equatable on depth
   struct DashTrayBackActionKey: PreferenceKey { … }
   ```

3. `DashSheetMenuButtons` / `DashSheetHeader`:收到 back action(depth > 0)时,同一个圆形按钮
   从 ✕ morph 成 ←,点按执行 pop;depth == 0 时还原为 ✕ 执行 dismiss。
   - 图标切换用两个 glyph 的 crossfade + 轻微旋转(`DashTheme.Motion.iconSwap`,160ms),
     这正是 Family 的 chevron 细节;Reduce Motion 时纯 opacity。
   - accessibilityLabel 在 "Close" / "Back" 间切换(两个 key 都要进 `Localizable.xcstrings`);
     `accessibilityIdentifier` 保持 `dash.tray.close` 不变(UI 测试兼容),另加 `dash.tray.back` 状态断言用。
   - 手势拖拽 dismiss 语义不变:拖拽永远关闭整个 tray,不是 pop。

4. 步进语义规则(写进 doc comment):
   - 前进 = `path.append(route)`;返回 = pop。
   - **终态步骤(成功页)必须替换栈而非入栈**(如 Add domain 的 `.created`:`path = [.created(name)]`
     且 role 提供为 `.root` 语义或单独禁 back),否则 back 会重新打开已提交的表单。
   - destructive 确认步(delete folder 等)正常入栈,back 即撤回。

5. 迁移三个现有调用点,删除各自 footer 里的 Cancel/Back 按钮,统一走 header ←。

**验收:**

- R2 Actions → Create folder:header ✕ 变 ←,← 回到 menu,menu 上 ✕ 关闭;拖拽任意步都直接关闭。
- Add domain 提交成功后 `.created` 步无 ← 可点(或 ← 不出现),✕ 关闭。
- `pnpm lint` + `pnpm lint:l10n` 通过;旧的单 route `DashTrayFlow` 调用点(如未迁移者)行为不变。

**风险:** preference 上报时机与 `DashTrayPopLayout` 的 pop-layout 高度测量并存 —— back action 变化不得
触发额外 resize 动画;用 depth 做 Equatable 隔离,避免闭包身份变化引起重渲染。

---

## P2 — DashTrayFlow 步进方向性动画

**Family 规则:** "fly instead of teleport" —— 前进时旧步向左让位、新步从右进入,返回反向。

**现状:** `DashTrayFlow` 的 transition 是对称的 `.opacity + .scale(0.96)`(`DashChrome.swift` ~L305–312),
无方向感。动画曲线已有:`trayStep` 270ms / `trayStepReturn` 220ms / `trayStepDestructive` 150ms。

**设计:**

1. 在 P1 的栈式 overload 内部记录上一次 depth,`depth 增 = forward`,`depth 减 = backward`
   (旧单 route overload 保持现状对称动画,不强加方向)。
2. asymmetric transition:
   - forward:incoming `offset(x: +step) + opacity`,outgoing `offset(x: -step) + opacity + scale(0.96)`;
   - backward 镜像。
   - `step` 建议 24pt,作为 token 放进 `DashTheme.Motion`(如 `trayStepSlide: CGFloat = 24`),不许散写字面量。
3. RTL:读 `\.layoutDirection` 环境值翻转偏移方向。
4. Reduce Motion:退回纯 opacity(现有惯例)。

**验收:** create-folder 前进/返回方向相反;Reduce Motion 下无位移;`trayResize` 高度动画与位移并行时无跳帧
(两者同时以各自 token 曲线运行即可,不要试图合并成一条动画)。

**依赖:** P1(方向来自栈 depth)。

---

## P3 — Tray 语境 tone

**Family 规则:** tray 的视觉主题随所在流程的上下文变化(暗色流程里 tray 变暗)。

**现状:** tray 背景固定 `#FEFFFE / #0F0F0F`(`DashTheme.swift` ~L348–400),只跟系统深浅色。
Dash 的「上下文」对应物是 `FeatureVisualIdentity.tone(for:)`(每个 feature 一个专属 tone)。

**设计:**

1. 新增环境值 `\.dashTrayTone: Color?`(默认 nil = 现状),由 `dashTray` 新增的可选参数注入
   (所有 overload 加 `tone: Color? = nil`,默认值保证零迁移成本)。
2. tone 的应用面**克制**,只上三处:
   - footer 主 submit pill 的 tint(`DashActionButton` 读环境值,显式传入者优先);
   - header 的 trailing action 圈(现在是固定 danger 红,destructive 语境保留红,其余用 tone);
   - 卡片顶部一层极淡的 tone wash(建议 ≤6% opacity 渐变,深色模式再减半)。禁止整卡换底色 ——
     tray 背景 token 保持唯一。
3. 接入点:feature 内发起的 tray(R2、KV、Zone 等)传 `FeatureVisualIdentity.tone(for: featureID)`;
   Home Quick actions 的 tray 传各自目标 feature 的 tone;Profile/Settings 的 tray 不传(中性)。

**验收:** R2 create-folder 的 submit pill 呈 R2 tone;Settings 语言 tray 与现状逐像素一致(nil 路径无回归);
深浅色两个 appearance 下 wash 不影响文字对比度。

**依赖:** 无(可与 P1/P2 并行)。

---

## P4 — DashMorphingLabel(共享字符的文案 morph)

**Family 规则:** Continue → Confirm 只动变化的字符,共享部分保持不动;同理用于「句子只变需要变的那部分」。

**现状:** `DashActionButton` 的 title 是 `.contentTransition(.opacity)`(`DashActionChrome.swift` ~L140–179);
数值已有 `.numericText`(两处)。无文字级 morph。

**设计:**

1. 新建 `DashMorphingLabel`(放 `DashControls.swift`):
   - 对**本地化后**的新旧字符串做公共前缀/后缀 diff(按 `Character`,CJK 天然可用);
   - 渲染为 `HStack(spacing: 0)` 三段 `Text`:prefix / 变化段 / suffix;变化段以 `.id(text)` +
     `.transition(.opacity.combined(with: .blur))` 切换(复用 `.dashMorph` 的参数感),
     前后缀不参与 transition,位置由布局自然平移(`DashTheme.Motion.morph` spring);
   - **单行限定**:HStack 分段破坏折行,故 API 层限制 `lineLimit(1)` 并在 doc comment 写明
     只用于按钮/徽章/胶囊类单行标签;多行文案不许用。
   - Reduce Motion:整串 opacity 切换,无位移。
2. 接入点(本期只做三处,验证手感):
   - `DashActionButton` title(状态型文案切换,如 Connect → Connecting 之外的确认类切换);
   - 危险操作 matched-geometry 确认流(红行 → 确认 pill)的文字层,补齐现有的物理 morph;
   - 「Add N wallets」同款:R2 多选删除的 `Delete N objects` 计数文案(计数部分即变化段)。
3. 纯数字继续用 `.numericText`,不要用本组件替代;顺手盘点:图表总量、对象计数、Load more 后的
   行数徽章统一补 `.numericText`(这是本项的搭车收益,改动极小)。

**验收:** 中英文环境下三处接入均只动变化段;Dynamic Type 最大号不截断(变化段变长时布局用 spring 平移);
Reduce Motion 无位移。

**依赖:** 无。

---

## P5 — Tray 从按钮中长出(anchor 呈现)

**Family 规则:** tray 可以「从组件内部长出来」(swap 按钮原地展开成 tray),保持上下文连续。

**现状:** 呈现是 scrim fade + 底部卡片上滑(`DashChrome.swift` ~L575–795)。tray host 是**禁用动画的
`fullScreenCover`** + 自绘 `DashCustomSheet`,坐标系与屏幕一致 —— 所以 anchor 起步动画可行,
不需要跨 presentation 的 matched geometry。

**设计:**

1. 新增 `.dashTraySource(id: AnyHashable)` modifier:用 `onGeometryChange`(global 坐标)把触发控件
   的 frame 写入一个随 `dashTray` modifier 传递的轻量 store(class,非 Observable 全量刷新)。
2. `dashTray` 各 overload 加可选 `sourceID: AnyHashable? = nil`;呈现时若能取到源 frame:
   - 卡片首帧以源 rect 的 scale/position 变换起步(渲染完整卡片做 transform,不做逐属性布局动画),
     以 `DashTheme.Motion.present` spring 到最终位置;
   - 同时把源按钮压暗/隐去(通过 store 回写一个 `isSourceOccupied`,源 modifier 读它把自身 opacity → 0),
     dismiss 完成后恢复 —— 这是 Family 的「组件不许在动画中复制自己」规则;
   - 关闭:仅 ✕ 关闭走反向收回;**拖拽 dismiss 保持现有下滑出场**(拖拽的物理方向是向下,强行拐去
     源按钮会违背手势直觉);scrim 点按同拖拽。
   - 无 sourceID 或取不到 frame:保持现有底部上滑,零回归。
3. 动态测高时序:首帧高度未定时,先以估算高度起步、`trayResize` 曲线跟进(现有机制已处理键盘/route
   高度变化,复用之)。
4. Reduce Motion:退回现状(fade + 上滑已是低motion,不再做变换)。
5. 首批接入:Home Quick actions 三个 `DashToolTile`(launcher 按钮,0.97 shrink + haptic 之后接
   「长出」正好一条连续手势)。其余入口观察手感后再扩。

**验收:** Quick action 按下 → tray 从 tile 位置长出,tile 本体隐去不重影;✕ 收回原位;拖拽仍向下滑出;
无 sourceID 的所有 tray 行为与现状逐帧一致。

**依赖:** 无硬依赖,但建议在 P1–P3 落地后做(改的是同一段呈现代码,避免并行冲突)。
**风险:** 本项是六项中改动面最大的,涉及 `DashCustomSheet` 呈现路径;单独一个 PR,方便整体 revert。

---

## P6 — 结果去向指示(探索项,最后做)

**Family 规则:** 交易确认后 spinner 飞进底部导航的 activity tab —— 告诉用户「结果去哪了」。

**范围(刻意最小):** 只做一个具体实例验证价值,不做通用系统。

- 实例:tray 内 submit 成功 → tray 收起时,submit pill 上的成功勾(现有尾部状态图标)脱离按钮,
  沿一条短弧线飞向 toast 落点(tray host 已拥有 toast host,同一坐标系),融入 toast 的 leading icon。
- 实现:tray host 层的一次性 overlay 动画(`DashTheme.Motion.settle`),Reduce Motion 直接跳 toast。
- 验收:Purge Cache(Home quick action)成功路径可见一次连续的「勾 → toast」;失败路径无此动画。

若手感好,后续候选:Pages retry → 指示物飞向 deployment 行;R2 上传完成 → 飞向对象行。**不在本期。**

---

## 内容编辑纪律(不写代码,写进 AGENTS.md)

1. **相邻 tray 步骤高度必须可感知地不同。** 动态测高已保证技术上高度跟随内容,但 Family 的规则是
   编辑纪律:若两步内容恰好等高,改写文案或调整布局让高度差出现,使「前进了」不言自明。
2. **每个 tray 只承载一件事**(一段说明或一个主操作)。现有用例已守住;新 tray 以此评审。

---

## 落地顺序与验证

| 顺序 | 项 | 改动集中在 | 单独 PR |
| --- | --- | --- | --- |
| 1 | P1 路由栈 + ✕→← | DashChrome.swift(+3 个调用点) | ✅ |
| 2 | P2 方向性步进 | DashChrome.swift + DashTheme.swift | 可并入 P1 |
| 3 | P3 语境 tone | DashChrome.swift + DashTheme.swift + 调用点传参 | ✅ |
| 4 | P4 MorphingLabel | DashControls.swift + 3 接入点 | ✅ |
| 5 | P5 anchor 呈现 | DashChrome.swift 呈现路径 + HomeView | ✅(必须) |
| 6 | P6 去向指示 | tray host + toast | ✅ |

每个 PR:`pnpm lint:fix` + `pnpm lint`(含 l10n / 架构检查);模拟器构建与测试按仓库惯例由用户批量验证,
不在 PR 流程内跑。全部落地后更新 AGENTS.md 的 tray 段落:✕→← 序列语义、方向性步进、tone 参数、
anchor 呈现的适用边界、两条编辑纪律。
