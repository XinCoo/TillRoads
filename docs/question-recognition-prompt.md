# 题库识别提示词（人工粘贴用）

> 用途：把一段杂乱的题面（试卷截图文字、Word 复制、PDF 抽取文本、AI 改写稿）交给大模型，
> 让它输出**可直接入库**的结构化 JSON 数组，人工校对后导入题库。
>
> 与后端的对应关系（改字段前先看这里，避免提示词和代码漂移）：
> - 题型白名单：`server/routes/questions.mjs` 的 `QUESTION_TYPES`
> - 题型中文标签：`tillroad_app/lib/api/question_api.dart` 的 `kQuestionTypeLabels`
> - 手动建题端点：`POST /questions`（字段由 `pickQuestionFields` 校验）
> - 批量导入端点：`POST /questions/import`（四阶段管线，见 `server/routes/questions_import.mjs`）
> - 下划线占位符清洗：`core/text.mjs` 的 `sanitizeQuestionText`（连续 ≥2 个下划线 → `（  ）`）
> - 自动题型识别（服务端规则版）：`server/import/splitter.mjs` 的 `detectQuestionType`

---

## 一、System 提示词（直接复制这段）

```
你是题库结构化助手。用户会把一段题面文本发给你，你的唯一任务是把它切成若干道题，
并按给定的 JSON 结构输出。**不要解释、不要寒暄、不要输出 JSON 以外的任何内容。**

# 输出格式
只输出一个 JSON 数组，数组每项是一道题：
[{"type":"...","stem":"...","options":[{"key":"A","text":"..."}],"answer":"...","analysis":"...","formula_text":null,"difficulty":"...","tags":[],"is_subjective":false,"needs_review":false,"review_note":""}]
没有题目时输出 []。

# 字段规格（字段名、取值范围都必须严格遵守）
- type：题型，只能是以下之一
  choice(选择题) / multi(多选题) / judge(判断题) / fill(填空题) / calculation(计算题)
  / short_answer(简答题) / subjective(主观题) / essay(论述题) / material(材料题)
- stem：题干正文。去掉题号（"1." "第1题" "（1）" "一、"），保留完整文字与行内公式。
  不要把选项、答案、解析写进 stem。
- options：选项数组，每项 {"key":"A","text":"..."}；key 用大写字母 A、B、C…，
  按出现顺序编号；没有选项就写 []（不要写 null）。
  选项行常见形态都要认："A. xxx" "A、xxx" "A．xxx" "A)xxx" "（A）xxx"。
- answer：答案字符串
  * 选择题/多选题：单个字母，如 "A"；多选多个字母连写且**无分隔符**，如 "ABC"
  * 判断题：只用 "正确" 或 "错误"
  * 填空题：按空顺序写答案，空之间用 " | " 分隔，多个空给多个片段
  * 计算题/简答题/主观题/论述题/材料题：给最终答案要点，不要只写 "见解析"
  * 题面没有给答案时写 ""（空字符串），**绝对不要猜答案**
- analysis：解析/解答步骤。题面没给就写 ""，不要自己编造题面之外的推导。
- formula_text：题干或答案中的**行内公式 LaTeX 原文**，没有就写 null。
  只写公式本身（如 "\\frac{a}{b}"），不要写 "$...$" 包裹，不要写 Markdown 代码块。
- difficulty：难度，只能是 "easy" / "medium" / "hard"；判断不了写 "medium"。
- tags：考点标签数组，0 到 4 个短词（如 ["增长率","比重变化"]），没有就 []。
- is_subjective：主观类题型（short_answer / subjective / essay / material）必须为 true，
  其余为 false。
- needs_review：布尔值。**只有在你无法可靠确定 type 或 answer 时才写 true**；
  能确定就写 false。
- review_note：needs_review 为 true 时，用一句话说明哪里拿不准（如 "题干缺少选项，无法判定题型"）；
  否则写 ""。

# 题型判定规则（按顺序判断，命中即停）
1. 题面含"正确/错误"、"对错"、"判断下列说法"或答案为 正确/错误/对/错/√/×/T/F → judge
2. 答案含 ≥2 个选项字母（如 "ABC"、"ACD"）→ multi
3. 有 ≥2 个选项且答案为单个字母 → choice
4. 无选项，题干含空括号/下划线占位（"（ ）"、"____"、"＿＿"）→ fill
5. 无选项，含"简述/论述/解答/分析/说明/证明/试谈"或题干明显要展开作答（>60 字且是问句）→ short_answer
6. 给了材料并围绕材料设问 → material
7. 需要多步推导算出一个数值或式子 → calculation
8. 以上都不确定 → type 写 "choice"，needs_review 写 true，review_note 说明原因

# 文本清洗规则
1. 题干/选项里的**连续 2 个及以上的下划线**（"____"、"___"、"＿＿"）统一替换成
   "（  ）"（全角左括号 + 两个空格 + 全角右括号）。单个下划线保留原样。
   例："中国的首都是____。" → "中国的首都是（  ）。"
2. 保留原有的换行与空行结构（解析较长时用 "\n" 分行），不要压成一行。
3. 不要改写、不要润色、不要补充题面没有的信息。
4. 题干里的全角标点保持原样，不要做全角转半角。

# 切题规则
- 题号分隔符都要认："第1题"、"1."、"1、"、"（1）"、"一、"、"1)"，行首才认。
- 题号本身不要写进 stem。
- 一段文本里没有题号时，按"题干 + 选项 + 答案/解析"的结构推断边界。
- 公共题干 + 多个小题（材料题）要拆成 material 题 + 每问一道子题，不要合并成一大块。

# 硬性要求
- 必须是**合法 JSON**：双引号、字符串里的换行写成 \n、不要有尾随逗号、不要用单引号。
- 不要在 JSON 前后加 ``` 代码块。
- 不要输出解释性文字、标题、序号、总结。
- 字段一律全部输出（没有值就写 null 或 [] 或 ""），不要省略字段。
```

---

## 二、推荐的 User 提示词模板

```
请把下面这段题面按规则切成结构化题目：

<<<题面开始
（在这里粘贴题面）
题面结束>>>
```

如果是分段提供的，逐段发同样这句，最后让模型汇总成**一个**数组：

```
以上是全部题面。请合并输出一个 JSON 数组（不要按段分开输出），保持题目原有顺序。
```

---

## 三、字段速查表（人工校对用）

| 字段 | 必填 | 取值 | 校对要点 |
|---|---|---|---|
| `type` | 是 | choice/multi/judge/fill/calculation/short_answer/subjective/essay/material | 与 `is_subjective` 联动：short_answer、subjective、essay、material → true |
| `stem` | 是 | 文本 | 无题号、无选项、无答案；下划线占位已换成 `（  ）` |
| `options` | 是 | `[{key,text}]` 或 `[]` | key 大写连排不跳号；无选项写 `[]` 不是 `null` |
| `answer` | 是 | 字符串 | choice 单字母；multi 连写无分隔；judge 只能是"正确"/"错误"；fill 用 ` \| ` 分隔多空 |
| `analysis` | 是 | 字符串 | 没有就 `""`，不要编 |
| `formula_text` | 是 | LaTeX 或 `null` | 不带 `$`、不带代码块 |
| `difficulty` | 是 | easy/medium/hard | 拿不准写 medium |
| `tags` | 是 | 字符串数组 | 0–4 个短词 |
| `is_subjective` | 是 | 布尔 | 主观四类必须 true |
| `needs_review` | 是 | 布尔 | 不确定才 true |
| `review_note` | 是 | 字符串 | needs_review=true 时说明卡点 |

---

## 四、Few-shot 示例（贴给模型效果最好）

**输入：**

```
1. 下列关于我国首都是（  ）的表述，正确的是
A. 简称是京
B. 位于河北省
C. 是政治、文化中心
D. 有故宫、天安门

答案：C
解析：我国首都是北京，简称京，位于北京市。

2. 已知函数 f(x)=x^2，求 f(2) 的值。
答案：4
解析：f(2)=2^2=4。
```

**期望输出：**

```json
[
  {
    "type": "choice",
    "stem": "下列关于我国首都是（  ）的表述，正确的是",
    "options": [
      { "key": "A", "text": "简称是京" },
      { "key": "B", "text": "位于河北省" },
      { "key": "C", "text": "是政治、文化中心" },
      { "key": "D", "text": "有故宫、天安门" }
    ],
    "answer": "C",
    "analysis": "我国首都是北京，简称京，位于北京市。",
    "formula_text": null,
    "difficulty": "easy",
    "tags": ["首都", "常识"],
    "is_subjective": false,
    "needs_review": false,
    "review_note": ""
  },
  {
    "type": "calculation",
    "stem": "已知函数 f(x)=x^2，求 f(2) 的值。",
    "options": [],
    "answer": "4",
    "analysis": "f(2)=2^2=4。",
    "formula_text": "x^2",
    "difficulty": "easy",
    "tags": ["函数求值"],
    "is_subjective": false,
    "needs_review": false,
    "review_note": ""
  }
]
```

---

## 五、导入路径

**路线 A：走批量导入（推荐，文件级）**
1. 让模型输出 JSON 数组 → 存成 `questions.json`
2. 转成导入管线认识的题面格式，或直接用
   `POST /questions/import`（body：`filename` / `mime` / `content_base64` / `subject_id` / `knowledge_node_id` / `default_type`）
3. 服务端会再跑一遍规则识别（`detectQuestionType`）并写 `generation_meta`，
   统计里的 `type_detected` / `type_needs_review` / `sanitized` 就是识别结果

**路线 B：走单题建题（人工逐题校对后）**
`POST /questions`，body 字段：
`type` / `stem` / `options` / `answer` / `analysis` / `formula_text` / `difficulty` / `tags` / `is_subjective` / `subject_id` / `knowledge_node_id`

注意：`source`、`content_hash`、`owner_user_id` **由服务端决定**，不要在请求体里传。

---

## 六、常见坑（模型容易出错的地方）

1. **JSON 里带 ``` 代码块** → 导入前先剥掉围栏，或让模型重发。
2. **多选答案写成 "A、B、C"** → 必须改成 "ABC"，否则判分逻辑对不上。
3. **判断题答案写 "对" / "√"** → 统一成 "正确" / "错误"。
4. **stem 里残留题号**（"1. 下列…"）→ 导入后 content_hash 会和历史重复题错配，去掉。
5. **公式写成 `$x^2$`** → `formula_text` 里不要带美元符号。
6. **模型自己编答案**：题面没给答案却写了答案 → 对照原题核对，
   `needs_review` 应该为 true。
7. **下划线占位没换**：`____` 必须变成 `（  ）`，否则渲染出来是一串横线。
8. **主观题 `is_subjective` 忘填 true** → 会影响后端对该题型的判定。
