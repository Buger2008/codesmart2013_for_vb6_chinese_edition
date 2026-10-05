# -*- coding: utf-8 -*-
r"""
translate.py —— 汉化预处理主入口（只做英译中）

**入口点和返回值固定不变：**

    translate(text) -> (处理后的文本, 是否需要翻译)

    · 不需要翻译 -> (原始文本, False)
    · 需要翻译   -> (处理后的文本, True)

调用方式：

    import translate

    new_text, need = translate.translate("Check out the \\b&entire \\bproject")
    # new_text = 'Check out the <strong>entire</strong> <strong>project</strong>'
    # need     = True

    new_text, need = translate.translate("书签已删除。")
    # new_text = '书签已删除。'
    # need     = False

---

内部流程（与 drawio 架构图逐节点对应）：

    入口 translate(text)
      │
      ├─ 节点1  判断是否需要翻译            -> judge(text)
      │            ├─ 否 ──> 返回 (原始文本, False)
      │            └─ 是 ──> 继续
      │
      ├─ 节点2  判断有没有 \b 以外的控制字符  -> has_non_bold_marker(text)
      │            ├─ 有 ──> 返回 (原始文本, False)    不需要翻译，& 也不动
      │            └─ 没有 ─> 继续
      │
      ├─ 临时   删掉所有 &                 -> STRIP_ALL_ACCELERATORS
      │            （'&' 是 VB 菜单加速键，会干扰翻译）
      │
      ├─ 节点3  判断有没有 \b               -> has_bold_marker(text)
      │            ├─ 没有 ─> 返回 (原始文本, True)     没东西可转，但要翻译
      │            └─ 有 ──> 继续
      │
      └─ 节点4  转换成 html                 -> translateprehtml.to_html(text)
                   └──> 返回 (转好 <strong> 的文本, True)

标记约定：

    \b  粗体。唯一需要处理的标记。作用于"紧跟其后的那个**词**"，不是成对开关。
        标点不算词，所以句号会留在标签外：
            'Check out the \b&entire \bproject'
            -> 'Check out the <strong>entire</strong> <strong>project</strong>'
            'Use \b<Ctrl+Enter> ... \blines.'
            -> 'Use <strong>&lt;Ctrl+Enter&gt;</strong> ... <strong>lines</strong>.'

    \e  控制字符。含 \e 的串在节点2就被拦下 —— **不需要翻译，返回 False**，
        整个不做处理、原样返回（连 & 都不动）。

    ⚠ 除 \b 以外的**任何**控制字符都按 \e 的待遇处理：不需要翻译、原样返回。
"""
import re

import translatejudge
import translateprehtml

# --------------------------------------------------------------------------- #
# 配置
# --------------------------------------------------------------------------- #
BOLD_MARKER = "b"                            # 唯一会被转换的标记

# --------------------------------------------------------------------------- #
# ⚠ 临时功能开关
#
# 是否在进入标记处理前，删掉 text 里所有 '&'。
# 原因：'&' 是 VB 菜单加速键，会影响翻译。
#
# 位置很关键：必须在【节点2 判断有没有 \b 以外的控制字符】之后 —— 因为含 \e 的串
# 要"原样返回"，连 & 都不能动；又必须在【节点3 判断有没有 \b】之前 —— 后面要转
# HTML，先把 & 清干净。
#
# 确认新版翻译器能自行处理 '&' 后，把这里改回 False 即可关闭。
# --------------------------------------------------------------------------- #
STRIP_ALL_ACCELERATORS = True


# --------------------------------------------------------------------------- #
# 底层辅助（外部不需要直接调用）
#
# 标记识别与 HTML 转换都委托给 translateprehtml —— 它提炼自 rtf_legacy.rs，
# 用逐字符扫描 + 最长前缀匹配，比原来的正则多做了这些：
#   · HTML 转义（& < >）—— 正则版不转义，'<Ctrl+Enter>' 会破坏 HTML
#   · 最长前缀匹配 —— '\ul' 不会被误判成 '\u' + 'l'
#   · 标记链 —— '\b\eCount' / '\b \eCount' 能正确处理
#   · 无对象兜底 —— 标记后面没东西时原样吐回，绝不丢内容
# --------------------------------------------------------------------------- #
def _find_markers(text):
    """返回文本里出现的所有控制字符标记集合。

    '\\b&entire \\bproject'  -> {'b'}
    'a \\b x \\e10'          -> {'b', 'e'}
    'a \\ul x'               -> {'ul'}     最长前缀匹配，不是 'u'
    '没有标记'                -> set()
    """
    return translateprehtml.find_markers(text)


def _bold_to_html(text):
    """节点4：把 \\b 转成 <strong>，并转义 & < >。

    \\b 作用于"紧跟其后的那个 token"，不是成对开关：
        'Check out the \\b&entire \\bproject'
        -> 'Check out the <strong>&amp;entire</strong> <strong>project</strong>'
        'Use \\b<Ctrl+Enter> ...'
        -> 'Use <strong>&lt;Ctrl+Enter&gt;</strong> ...'
    """
    return translateprehtml.to_html(text, convert={BOLD_MARKER})


# 自检用：找出输出里"还残留的可转换标记"（\b 后面还跟着 token）。
# 孤立的 \b（后面没有 token）按 translateprehtml 的设计**原样保留**，不算残留
# —— 那是"绝不丢内容"原则，宁可留个可见的标记，也不静默吃掉。
_LEFTOVER_RE = re.compile(r"\\b(?=\S)")


def _leftover(text):
    """输出里是否还有没转换掉的标记"""
    return _LEFTOVER_RE.findall(text)


# --------------------------------------------------------------------------- #
# 节点判断函数（对应架构图里的菱形判断）
# --------------------------------------------------------------------------- #
def has_non_bold_marker(text):
    """节点2：判断有没有 \\b 以外的控制字符。

    除 \\b 外的任何标记都算 —— \\e 以及将来可能出现的其它控制字符。
    返回 True 表示"有"，该串**不需要翻译**，原样返回（连 & 都不动）。

    例：
        'a \\b x \\e y'    -> True    （有 \\e）
        'a \\e y'          -> True    （有 \\e）
        'a \\b x \\b y'    -> False   （只有 \\b）
        '没有标记'          -> False
    """
    return bool(_find_markers(text) - {BOLD_MARKER})


def has_bold_marker(text):
    """节点3：判断有没有 \\b。

    返回 True 表示"有 \\b"，可以进入节点4做转换。
    """
    return BOLD_MARKER in _find_markers(text)


# --------------------------------------------------------------------------- #
# 对外唯一入口
# --------------------------------------------------------------------------- #
def translate(text):
    """汉化预处理主入口。入口点和返回值固定不变。

    参数:
        text   待处理字符串。传 None 返回 ("", False)；非字符串自动 str()

    返回:
        (处理后的文本: str, 是否需要翻译: bool)

        不需要翻译 -> (原始文本, False)
        需要翻译   -> (处理后的文本, True)
                      · 含 \b 以外的控制字符 / 无标记 -> 处理后的文本就是原始文本
                      · 只有 \b                       -> 已把 \b 转成 <strong>…</strong>
    """
    # ---------------- 入口 ----------------
    if text is None:
        return "", False
    if not isinstance(text, str):
        text = str(text)

    # ---------------- 节点1：判断是否需要翻译 ----------------
    # judge 内部已内置禁止中文，含中文的串在这里返回 False
    if not translatejudge.judge(text):
        return text, False

    # ---------------- 节点2：判断有没有 \b 以外的控制字符 ----------------
    if has_non_bold_marker(text):
        return text, False                # 有 -> 不需要翻译，原样返回（& 也不动）

    # ---------------- 临时功能：删掉所有 & ----------------
    # '&' 是 VB 菜单加速键，会干扰翻译，所以这里整串清掉。
    # 放在节点2之后（含 \e 的串要原样返回，不能动它的 &）、
    # 节点3之前（后面要转 HTML，先把 & 清掉）。
    if STRIP_ALL_ACCELERATORS:
        text = text.replace("&", "")

    # ---------------- 节点3：判断有没有 \b ----------------
    if not has_bold_marker(text):
        return text, True                 # 没有 \b -> 没东西可转

    # ---------------- 节点4：转换成 html ----------------
    return _bold_to_html(text), True


# 对外别名 / 兼容旧名字
bold_to_html = _bold_to_html          # 节点4 的实现，可单独调用测试
markers_to_html = _bold_to_html       # 旧名字
find_markers = _find_markers


# --------------------------------------------------------------------------- #
# 自检 / 命令行
# --------------------------------------------------------------------------- #
if __name__ == "__main__":
    import sys

    if "--flow" in sys.argv:
        # 走全部分支；英文串用假的 judge 结果，不联网
        print("=== 分支验证（不联网，英文串模拟 judge 判定）===")
        cases = [
            # (输入, 假判定, 期望 need, 说明)
            ("书签已删除。", False, False, "节点1 否：含中文"),
            ("标签顺序设计器......", False, False, "节点1 否：含中文"),
            (r"应用新过滤设置时 \b刷新 树", False, False, "节点1 否：含中文（即使有 \\b）"),
            ("&Next >>", True, True, "节点3 没有 \\b -> (删&文本, True)"),
            ("Invalid file name", True, True, "节点3 没有 \\b -> (原文, True)"),
            (r"Check out the \b&entire \bproject", True, True, "只有 \\b -> 节点4 转粗体"),
            (r"&Do \bnot \bshow this again", True, True, "只有 \\b -> 节点4 转粗体"),
            (r"Use \b<Ctrl+Enter> to wrap text on \bmultiple \blines.", True, True, "只有 \\b -> 节点4 转粗体"),
            (r"When \bviewing a procedure for \bmore \bthan \e10 seconds", True, False, "节点2 有 \\e -> (原文, False)"),
            (r"Maximum number of \bvisible \bhistory \bitems: \e10 (...)", True, False, "节点2 有 \\e -> (原文, False)"),
            (r"a \b x \e y", True, False, "节点2 有 \\e -> (原文, False)"),
            (r"a \e y", True, False, "节点2 有 \\e（无 \\b）-> (原文, False)"),
            (r"\ulUnderlined text", True, False, "节点2 有 \\ul（非 \\b）-> (原文, False)"),
            (r"Settings\Bookmark", True, True, "大写 \\B 不是标记（标记只认小写）-> 无标记"),
        ]
        real_judge = translatejudge.judge
        bad = 0
        for s, fake, want_need, note in cases:
            translatejudge.judge = lambda t, _f=fake: _f
            out, need = translate(s)
            ok = (need == want_need)
            # 完整性断言：需要翻译的输出里，绝不能残留"可转换的标记"
            leftover = _leftover(out)
            if need and leftover:
                ok = False
                note += "  ← 输出残留标记 %s" % leftover
            bad += (not ok)
            print("  [%s] need=%-5s 转换=%-2s %-36s %r"
                  % ("OK " if ok else "FAIL", need, "是" if out != s else "否", note, s[:38]))
            if out != s:
                print("                -> %r" % out[:66])
        translatejudge.judge = real_judge
        print()
        print("分支验证: %d/%d 通过" % (len(cases) - bad, len(cases)))
        sys.exit(1 if bad else 0)

    if "--nodes" in sys.argv:
        # 单独验证两个节点判断函数，不联网
        print("=== 节点判断函数验证（不联网）===")
        print("%-46s %-14s %s" % ("输入", "节点2(有非\\b)", "节点3(有\\b)"))
        print("-" * 78)
        for s in [r"a \b x \b y", r"a \b x \e y", r"a \e y",
                  r"a \ul x", r"\ulUnderlined", "没有标记",
                  r"Settings\Bookmark", r"\Bookmark",
                  r"\bSkip &matches"]:
            print("%-46r %-14s %s" % (s[:44], has_non_bold_marker(s), has_bold_marker(s)))
        print()
        print("节点2 = True 表示【不需要翻译】，直接返回 False")
        print("注：标记只认小写 b/i/u/ul/e —— '\\Bookmark' 的大写 B 不是标记，")
        print("    这类反斜杠路径由【节点1 judge()】负责拦（G8 路径 / G5 无空格）。")
        print()
        print("=== 节点4（\\b 转 <strong>）验证，不联网 ===")
        print("%-46s %s" % ("输入", "输出"))
        print("-" * 78)
        for s in [r"Check out the \b&entire \bproject",
                  r"&Do \bnot \bshow this again",
                  r"Use \b<Ctrl+Enter> to wrap text on \bmultiple \blines.",
                  r"\b前面没东西",
                  r"\b\eCount",
                  r"\ul下划线",
                  r"孤立在串尾的 \b",
                  r"a & b <tag> c",
                  "没有标记"]:
            out = bold_to_html(s)
            leftover = _leftover(out)
            print("%-46r %r%s" % (s[:44], out[:44],
                                  "   ← 残留 %s" % leftover if leftover else ""))
        sys.exit(0)

    if "--local" in sys.argv:
        # 真实调用 judge（中文走内置规则，零请求）
        for s in ["书签已删除。", r"应用新过滤设置时 \b刷新 树", "标签顺序设计器......"]:
            out, need = translate(s)
            print("need=%-5s  %r  ->  %r" % (need, s, out))
        print("(均含中文，judge 内置禁止中文，零请求)")
        sys.exit(0)

    if not sys.argv[1:]:
        print("用法:")
        print("  python translate.py <text>         # 主用法：打印两行")
        print("                                       第 1 行 true / false")
        print("                                       第 2 行 处理后的文本")
        print()
        print("  python translate.py --flow         # 验证全部分支，不联网")
        print("  python translate.py --nodes        # 单独验证节点2/3/4，不联网")
        print("  python translate.py --local        # 测中文短路，不联网")
        sys.exit(0)

    # ---- 主用法：把所有位置参数当**一句话**（多个参数用空格拼回，方便不加引号）----
    # 输出严格两行：第 1 行 true/false，第 2 行处理后的文本
    text = " ".join(sys.argv[1:])
    out, need = translate(text)
    print("true" if need else "false")
    print(out)
