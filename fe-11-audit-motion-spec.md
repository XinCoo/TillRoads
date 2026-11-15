# FE-11 审核七态 UI · 动效规格（iOS 原生风格，与七态状态机一并冻结）

> 版本: v1.1 | 文件名对应: `fe-11-audit-motion-spec.md`（由 `fe-02-motion-spec.md` 改名；原 FE-02 实为「建题/导入页」，改名避免检索混淆，内容不变）
> 配套: `byok-key-lifecycle.md` v1.2（七态状态机）、`mvp-tasks.md` FE-11（审核七态 UI）
> 目的: 把「动效风格」钉死为可执行的参数区间，避免原型交付后动效返工。
> 使用方式: 任何 UI/前端 AI 或工程师实现 FE-11（及 App 内其它转场）时，直接粘贴下方的「iOS 原生动效基准」提示词，并对照「七态转场表」逐态实现。
> v1.1 修订: 修正 iOS 版本号锚点（改「现行 iOS 26 系列」）、弹簧参数改为阻尼比两档（靠近临界阻尼）、新增 Reduce Motion 与低端机性能降级、补充 sheet detents 与触觉同帧触发。

---

## 一、iOS 原生动效基准（可直接粘贴给 UI/前端 AI）

```text
【动效风格需求：iOS 原生风格】
基准参照：以**现行 iOS（26 系列）原生系统应用**（设置、App Store、信息、备忘录）的交互动效为唯一基准；动效语言以 iOS 18 之后稳定形态为准（iOS 7 之后交互动效体系基本稳定，具体小版本号对实现影响很小）。不要引用任何不存在的 iOS 版本号作为特性锚点。
不要用 Material Design 的动效语言作为默认值。
一、转场（页面层级）
1. push/pop：新页面从右侧滑入，旧页面同时向左视差移动约 30% 宽度，带轻微暗化；
   返回时反向。禁止使用 Android 的共享轴（shared axis）或淡入淡出作为页面转场。
2. 模态（modal sheet）：从底部升起，背景内容缩小并暗化（scale 约 0.92 + 圆角），支持 medium/large 两档 detent 停靠（下拉可停在 medium）；
   审核七态中 `credential_invalid` 用 medium detent 即可，不必 large；下拉可交互关闭，松手时按速度决定回弹或关闭。
3. 大标题折叠：滚动时大标题随内容上移缩小为导航栏标题，用连续插值，不要跳变。
二、手势（必须手指跟随）
1. 边缘右滑返回：页面位置实时跟随手指位移，松手后按速度决定完成或取消。
2. 下拉刷新：内容跟随手指下拉，达到阈值后触发，回弹用 spring。
3. 长按上下文菜单：触觉反馈 + 背景模糊 + 菜单从按压点附近缩放展开。
4. 所有可滑动删除/操作的行，必须支持跟手位移，不能只支持按钮触发。
三、弹性物理（用阻尼比而非绝对刚度/阻尼值，靠近临界阻尼）
1. 交互驱动的动画（松手回弹、sheet 关闭、菜单展开）使用 spring 动画，按场景分两档阻尼比：
   - 页面/内容过渡（push/pop、状态原地切换）：damping ratio **0.85–0.95**，接近临界阻尼，回弹克制；
   - 松手回弹 / sheet 关闭 / 菜单展开：damping ratio **0.75–0.85**，允许轻微回弹。
   Flutter 用 `SpringDescription.withDampingRatio(ratio: ..., stiffness: 180–260, mass: 1)`，
   不同位移下手感一致；**不要用 `Curves.elasticOut` 冒充弹簧**（那是假弹性、过冲不可控，且 iOS 原生默认接近临界阻尼）。
2. 非交互的过渡（状态切换、内容出现）可用 ease-in-out，时长 200–350ms，
   禁止超过 400ms 的页面级过渡。
3. 禁止使用 Material 的 standard easing 曲线作为默认值。
四、材质与模糊
1. 导航栏、Tab 栏、模态背景使用 backdrop blur + 半透明材质，
   参考 blur radius 20–30，透明度按层级区分。
2. 滚动内容在导航栏下方时，用模糊+渐隐过渡，不要硬切分割线。
3. 禁止用纯色不透明导航栏覆盖滚动内容。
五、触觉反馈
1. 轻触选择、开关切换、长按触发、验证通过/失败，分别对应不同的 haptic 强度。
2. 触觉与视觉动画**同一帧触发**（`HapticFeedback` 调用不晚于动画首帧），不要等动画开始后再调用，否则会有「先看到再感觉到」的割裂。
六、反面清单（出现即视为不符合）
- Material ripple / ink splash
- Android 的共享轴转场、容器变换转场
- 线性或 ease 曲线驱动的松手回弹
- 页面转场时长 > 400ms
- 无手势跟随的“点击后播放动画”
- 纯色不透明导航栏硬切滚动内容
- 底部 sheet 无背景缩放/暗化
七、Flutter 技术映射
- 优先使用 Cupertino 组件与 CupertinoPageRoute；
- 弹簧动画用 `SpringDescription.withDampingRatio(ratio: 0.8, stiffness: 220, mass: 1)`（按场景取 0.75–0.95），不要用 Curves.elasticOut 冒充；
- 模糊用 BackdropFilter + ImageFilter.blur；
- 触觉用 HapticFeedback.lightImpact / mediumImpact / selectionClick；
- 边缘返回优先用 CupertinoPageRoute 自带手势，自定义页面需手动实现跟手位移。

八、无障碍与性能降级（Reduce Motion / 低端机，必须实现，否则审核可能被无障碍问题卡住）
1. 减弱动态效果（Reduce Motion）：必须响应系统「设置 → 辅助功能 → 动态效果 → 减弱动态效果」。
   Flutter 中读 `MediaQuery.disableAnimations`；为 true 时：关闭视差、关闭缩放、关闭弹簧回弹，
   统一降级为 ≤200ms 的淡入淡出或直接切换。第三节与七态转场表中的所有 spring/视差/scale 在此模式下全部失效。
2. 性能降级（BackdropFilter 在低端安卓全屏模糊很卡）：
   - BackdropFilter 仅在能力足够的设备启用；低端机降级为半透明纯色叠层，避免掉帧；
   - **列表（ListView/GridView）内不要嵌套 BackdropFilter**（每行都建模糊层会雪崩掉帧）；
   - 模态背景模糊可用，但避免在长列表里对每行做模糊。
3. 触觉降级：系统开启「减少触觉反馈」或设备不支持时，静默跳过 HapticFeedback 调用，不要抛错。
```

---

## 二、最容易被 AI / 工程师漏掉的 5 个点

1. **手势跟随**：默认做「点击→播放动画」，而不是「手指拖到哪页面到哪」。必须显式要求 interactive transition。
2. **视差**：push 时旧页面不是静止的，要反向移动。不写这条，AI 会做成新页面盖上去。
3. **弹簧参数**：只说「弹性」会用 `Curves.elasticOut`，那是假的弹簧。必须给 `SpringDescription.withDampingRatio` 与阻尼比两档区间（页面过渡 0.85–0.95 / 回弹 0.75–0.85）；不要给绝对 stiffness/damping 值（如 220/26 对应阻尼比 ≈0.88，反而比 iOS 原生更弹、失真）。
4. **模态的背景缩放**：iOS 的 sheet 升起时背景会缩小并加圆角，AI 通常只做暗化不做缩放。
5. **反面清单**：不列 Material ripple 和共享轴转场，AI 会混用两套语言。

---

## 三、FE-11 七态转场表（状态机已冻结，转场一并冻结）

| 状态 | 进入方式 | 退出方式 | 关键动效参数 |
|---|---|---|---|
| `generating` | 从触发页 push（新页右滑入，旧页左视差≈30%宽+轻暗化） | 生成完成→**原地过渡**至 `pending_review`（不 push 新页） | spring（damping ratio 0.85–0.95）；无触觉 |
| `validation_failed` | 同页内状态切换（200–350ms ease-in-out，无跳转），失败项标红+图标 | 编辑/重新生成→回 `generating`（原地，spring 回弹）；手动编辑后：先由**客户端本地结构校验**（字段完整/格式合法/必填非空），通过后再**提交后端重走自动校验**（结构缺失 / `content_hash` 重复 / LaTeX 非法），通过则回 `pending_review`，仍失败保持 `validation_failed`（与 `byok-key-lifecycle.md` 5.1 一致，本地校验不替代后端校验） | selectionClick（标记失败时） |
| `pending_review` | 从 `generating` 原地过渡（spring，damping ratio 0.85–0.95） | 逐题/批量确认→`approved`（lightImpact+250ms 确认动画）；拒绝→`rejected` | lightImpact / mediumImpact |
| `approved` | 原地更新 + 轻触觉(lightImpact) + 短确认动画(spring damping ratio 0.85–0.95, 250ms) | 可回溯删除→回 `pending_review`（原地） | lightImpact |
| `rejected` | 原地更新，归档提示（无跳转，mediumImpact） | 可恢复重审→回 `pending_review`（原地） | mediumImpact |
| `credential_invalid` | 从任意 AI 触发点以 **banner/sheet（medium detent）** 出现（非整页跳转），spring 从底部升起(damping ratio 0.75–0.85)+背景 scale≈0.92 暗化 | 去设置→push（新页右滑入）；稍后重试→关闭 banner（spring 回弹） | mediumImpact |
| `cooldown` | 同 `credential_invalid`，banner 显示剩余冷却时间（倒计时） | 倒计时结束（`cooldown_until` 到期）：若用户仍在 sheet 内则原地刷新为可用态并提示「已恢复，可重试」，否则 sheet 自动关闭并 toast「密钥已恢复，可重试」；或用户更新密钥后手动解除→清零 `consecutive_failures` | mediumImpact |

**两条硬约束（贯穿七态）**：
- `credential_invalid` 与 `cooldown` **一律用非阻塞底部 sheet（medium detent）+ 暗化**，绝不整页错误页（不打断当前上下文）。
- 所有状态切换禁止「无手势跟随的点击后播放动画」；页面级转场 ≤400ms；弹簧必须用 `SpringDescription.withDampingRatio` 而非 `Curves.elasticOut`。
- 开启系统「减弱动态效果」(`MediaQuery.disableAnimations=true`) 时，上述所有 spring/视差/缩放降级为 ≤200ms 淡入淡出（见第八节）；触觉静默跳过。

> 原型可视化见对话内联的 7 张 FE-11 七态 mockup（generating / validation_failed / pending_review / approved / rejected / credential_invalid / cooldown），每态右侧附转场规格卡。
