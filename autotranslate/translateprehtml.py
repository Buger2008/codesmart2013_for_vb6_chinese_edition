# -*- coding: utf-8 -*-
r"""
translateprehtml.py —— 词级标记 -> HTML（翻译预处理专用）

提炼自 `rtf_legacy.rs` 的核心实现，用于架构里的【节点4：转换成 html】。

VB6 时代 OCX 的私有方言：标记只作用于紧随其后的**一个单词**，且不加分隔符。
    \b<word>   该词加粗
    \i<word>   该词斜体
    \u<word>   该词下划线
    \ul<word>  该词下划线（双字符标记）
    \e<word>   该词可编辑（OCX 里是可输入字段槽）

⚠ 合规 RTF 解析器会把 `\bmay` 当成未知控制字 "bmay"，静默吞掉整个单词，
  所以不能用任何 RTF 库，只能按此方言自己解析。

---

## 为什么不继续用正则

原来 translate.py 用一条 `\\b(\S+)` 搞定，简单但有 4 个硬伤：

1. **不做 HTML 转义** —— 文本里的 `&` `<` `>` 会破坏 HTML：
       'Use \b<Ctrl+Enter> ...' -> 'Use <b><Ctrl+Enter></b> ...'   ← 尖括号没转义
2. **只认单字符标记** —— `\ul`（下划线）会被误判成 `\u` + 字面 'l'
3. **标记后面没有对象时直接删掉** —— 丢内容（违背"绝不丢东西"原则）
4. **不支持标记链** —— `\b\eCount` / `\b \eCount` 这类叠加处理不了

Rust 版是**逐字符扫描 + 最长前缀匹配**，把上面四个问题都解决了。

## 本文件相对 Rust 版的取舍

保留（精髓）：
    · HTML 转义
    · 逐字符扫描 + 最长前缀匹配
    · 标记链（\b\eCount / \b \eCount）
    · 无对象兜底：标记后面没东西就原样吐回，绝不静默丢弃
    · 步数上限保护，绝不死循环
    · 十六进制转义 \'XX（cp1252）与 \\ \{ \} 转义字符

去掉（当前架构用不到）：
    · RTF 控制字表（\par \line \emdash ...）
    · markdown / 纯文本输出格式
    · --editable 的 input / span 模式
    · 扫描统计（--scan）

## 对外接口

    find_markers(text) -> set[str]     文本里出现哪些标记字母，如 {'b'}、{'b','e'}
    to_html(text, ...) -> str          \b -> <strong>，其余标记原样保留
    escape_html(s) -> str              转义 & < >
"""

# --------------------------------------------------------------------------- #
# 标记表
# --------------------------------------------------------------------------- #
# 词级标记 -> HTML 开闭标签。顺序无关，匹配时按"最长前缀优先"。
MARKER_TAGS = {
    "ul": ("<u>", "</u>"),
    "b": ("<strong>", "</strong>"),
    "i": ("<em>", "</em>"),
    "u": ("<u>", "</u>"),
    "e": ("", ""),          # \e 默认不转换，走"原样保留"
}

# 参与识别的所有标记键（用于最长前缀匹配，最长 2 字符）
ALL_MARKER_KEYS = ("ul", "b", "i", "u", "e")

# 默认只转换 \b —— 与架构约定一致（只有 \b 需要处理）
DEFAULT_CONVERT = frozenset({"b"})

# 未纳入 convert 的标记怎么处理：
#   "verbatim" 逐字符原样保留（默认，绝不丢东西）
#   "text"     去掉标记字母、保留后面的内容
#   "drop"     整个丢掉
DEFAULT_OTHER = "verbatim"

# 是否转义 & < >。默认开 —— 输出要当 HTML 用，不转义就是坏 HTML。
DEFAULT_ESCAPE = True


# --------------------------------------------------------------------------- #
# 小工具
# --------------------------------------------------------------------------- #
def escape_html(s):
    """HTML 转义：& -> &amp;  < -> &lt;  > -> &gt;"""
    out = []
    for c in s:
        if c == "&":
            out.append("&amp;")
        elif c == "<":
            out.append("&lt;")
        elif c == ">":
            out.append("&gt;")
        else:
            out.append(c)
    return "".join(out)


def _esc(s, escape):
    return escape_html(s) if escape else s


# cp1252 的 0x80-0x9F 段（RTF 的 \'XX 用的是这个码表，不是 Latin-1）
_CP1252 = {
    0x80: "\u20ac", 0x82: "\u201a", 0x83: "\u0192", 0x84: "\u201e",
    0x85: "\u2026", 0x86: "\u2020", 0x87: "\u2021", 0x88: "\u02c6",
    0x89: "\u2030", 0x8a: "\u0160", 0x8b: "\u2039", 0x8c: "\u0152",
    0x8e: "\u017d", 0x91: "\u2018", 0x92: "\u2019", 0x93: "\u201c",
    0x94: "\u201d", 0x95: "\u2022", 0x96: "\u2013", 0x97: "\u2014",
    0x98: "\u02dc", 0x99: "\u2122", 0x9a: "\u0161", 0x9b: "\u203a",
    0x9c: "\u0153", 0x9e: "\u017e", 0x9f: "\u0178",
}


def _cp1252(b):
    return _CP1252.get(b, chr(b))


def _hex_val(c):
    try:
        return int(c, 16)
    except ValueError:
        return None


def _parse_ctrl(chars, i):
    """解析 `\\word[NNN]`。

    调用者须保证 chars[i] == '\\\\' 且 chars[i+1] 是 ASCII 字母。
    返回 (字母部分, 数字参数字符串或 None, token 结束下标)
    """
    n = len(chars)
    j = i + 1
    while j < n and chars[j].isascii() and chars[j].isalpha():
        j += 1
    word = "".join(chars[i + 1:j])

    num_start = j
    k = j
    # 只有 '-' 后面真的跟数字时才算负数参数。
    # ⚠ 不能无条件跳过 '-' —— 否则 '\bread-only' 的破折号会被当成参数前缀吃掉，
    #   结果变成 <strong>read-</strong>only（Rust 版也有这个 bug，已修）。
    if (k + 1 < n and chars[k] == "-"
            and chars[k + 1].isascii() and chars[k + 1].isdigit()):
        k += 1
    digits_from = k
    while k < n and chars[k].isascii() and chars[k].isdigit():
        k += 1
    num = "".join(chars[num_start:k]) if k > digits_from else None
    return word, num, k


def _longest_marker(word):
    """在所有标记键上做最长前缀匹配。

    'b'      -> ('b', 1)
    'ul'     -> ('ul', 2)      ← 不是 'u' + 'l'
    'emdash' -> ('e', 1)
    'xyz'    -> (None, 0)
    """
    limit = min(len(word), 3)
    for length in range(limit, 0, -1):
        prefix = word[:length]
        if prefix in ALL_MARKER_KEYS:
            return prefix, length
    return None, 0


# 带数字参数时要特殊对待的标记。
# RTF 里 `\uNNNN` 是 Unicode 转义（不是"给 NNNN 加下划线"），所以 u 带数字时
# 不转换、原样保留。
# 其余标记的数字只是词的一部分（\bVB6、\b2 里的 VB6 / 2），照常转换。
_NUMERIC_ESCAPE_MARKERS = frozenset({"u"})


def _decide(word, has_num, convert):
    """决定这个 token 怎么处理。

    返回 ('convert', key, hit, open, close) / ('other',)
    """
    key, hit = _longest_marker(word)
    if key is None:
        return ("other",)
    open_tag, close_tag = MARKER_TAGS[key]
    if key in convert and not (has_num and key in _NUMERIC_ESCAPE_MARKERS):
        return ("convert", key, hit, open_tag, close_tag)
    return ("other",)


# --------------------------------------------------------------------------- #
# 对外：找标记（供节点2 / 节点3 用）
# --------------------------------------------------------------------------- #
def find_markers(text):
    """返回文本里出现的所有标记字母集合。

    '\\b&entire \\bproject'  -> {'b'}
    'a \\e10 b'              -> {'e'}
    'a \\b x \\e10'          -> {'b', 'e'}
    'a \\ul x'               -> {'ul'}     ← 最长前缀匹配，不是 'u'
    '没有标记'                -> set()
    """
    chars = list(text)
    n = len(chars)
    found = set()
    i = 0
    while i < n:
        if chars[i] == "\\" and i + 1 < n and chars[i + 1].isascii() and chars[i + 1].isalpha():
            word, _num, end = _parse_ctrl(chars, i)
            key, _hit = _longest_marker(word)
            if key:
                found.add(key)
            i = end
            continue
        i += 1
    return found


# --------------------------------------------------------------------------- #
# 对外：转 HTML（节点4）
# --------------------------------------------------------------------------- #
def to_html(text, convert=DEFAULT_CONVERT, other=DEFAULT_OTHER, escape=DEFAULT_ESCAPE):
    """把词级标记转成 HTML。

    参数:
        text     待转换字符串
        convert  要转换的标记键集合，默认 {'b'}（只有 \\b 转）
        other    未转换标记的处理：verbatim（默认，原样保留）/ text / drop
        escape   是否转义 & < >，默认 True

    返回:
        转换后的字符串。

    保证:
        · 绝不丢内容 —— 标记后面没有对象时原样吐回
        · 绝不死循环 —— 有步数上限保护
        · escape=True 时输出是合法 HTML
    """
    convert = set(convert)
    chars = list(text)
    n = len(chars)
    out = []
    i = 0
    steps = 0
    # 硬保险：即使将来逻辑改错，也绝不可能无限循环/撑爆内存
    max_steps = 8 * n + 32

    while i < n:
        start = i
        steps += 1
        if steps > max_steps:
            raise RuntimeError(
                "内部错误：步数超出上限 (i=%d, n=%d)，已中止以保护内存" % (i, n))

        # ---- 非反斜杠 ----
        if chars[i] != "\\":
            out.append(_esc(chars[i], escape))
            i += 1
            continue

        # ---- 结尾孤立反斜杠 ----
        if i + 1 >= n:
            out.append("\\")
            i += 1
            continue

        nxt = chars[i + 1]

        # ---- 控制符号 / 十六进制转义 ----
        if not (nxt.isascii() and nxt.isalpha()):
            if nxt == "'" and i + 3 < n:
                hi, lo = _hex_val(chars[i + 2]), _hex_val(chars[i + 3])
                if hi is not None and lo is not None:
                    out.append(_esc(_cp1252(hi * 16 + lo), escape))
                    i += 4
                    continue
            # \{ \} \\ 是转义字符；其余控制符号在当前方言里没有依据，一律原样保留
            if nxt in ("\\", "{", "}"):
                out.append(_esc(nxt, escape))
                i += 2
            else:
                out.append(_esc(chars[i], escape))
                i += 1
            continue

        # ---- 词 / 标记 ----
        word, num, tok_end = _parse_ctrl(chars, i)
        has_num = num is not None
        decision = _decide(word, has_num, convert)

        if decision[0] == "convert":
            _tag, key, hit, open_tag, close_tag = decision
            # 被标记的内容 = 标记字母之后、token 结束之前的全部字符
            # （必须用 tok_end，不能用 word 的长度 —— 否则 \bVB6 里的 "6" 会被丢掉）
            word_text = "".join(chars[i + 1 + hit:tok_end])
            chain = [(key, open_tag, close_tag)]
            cur_end = tok_end

            # 收集标记链：支持 \b\eCount / \b \eCount 这类叠加
            while not word_text:
                p = cur_end
                if p < n and chars[p] == " ":
                    p += 1                      # 分隔符被控制字吃掉，不产生输出
                if (p < n and chars[p] == "\\" and p + 1 < n
                        and chars[p + 1].isascii() and chars[p + 1].isalpha()):
                    w2, num2, end2 = _parse_ctrl(chars, p)
                    d2 = _decide(w2, num2 is not None, convert)
                    if d2[0] == "convert":
                        _t, k2, h2, o2, c2 = d2
                        chain.append((k2, o2, c2))
                        word_text = "".join(chars[p + 1 + h2:end2])
                        cur_end = end2
                        continue
                    # 下一个 token 不转换 -> 把它**原样**当作被标记的内容，
                    # 既保住 \e 标记，又让外层 \b 生效
                    if other == "verbatim":
                        word_text = "".join(chars[p:end2])
                        cur_end = end2
                        continue
                    if other == "text":
                        word_text = "".join(w2[1:])
                        cur_end = end2
                        continue
                    cur_end = end2                  # drop：丢弃该 token，继续找真正的单词
                    continue
                if p < n and not chars[p].isspace():
                    q = p
                    while q < n and not chars[q].isspace():
                        q += 1
                    word_text = "".join(chars[p:q])
                    cur_end = q
                else:
                    cur_end = p
                break

            if not word_text:
                # 标记后面没有可作用的对象：原样吐回，绝不静默丢弃
                out.append(_esc("".join(chars[start:tok_end]), escape))
                cur_end = tok_end
            else:
                # 按链顺序开标签，逆序闭标签
                for _k, o, _c in chain:
                    out.append(o)
                out.append(_esc(word_text, escape))
                for _k, _o, c in reversed(chain):
                    out.append(c)
            i = cur_end
            if i <= start:
                raise RuntimeError("内部错误：下标未前进")
            continue

        # ---- 不处理 ----
        if other == "verbatim":
            out.append(_esc("".join(chars[start:tok_end]), escape))
        elif other == "text":
            out.append(_esc("".join(chars[i + 2:tok_end]), escape))
        # drop：什么都不输出
        i = tok_end
        if i <= start:
            raise RuntimeError("内部错误：下标未前进")

    return "".join(out)


# --------------------------------------------------------------------------- #
# 自检
# --------------------------------------------------------------------------- #
if __name__ == "__main__":
    import sys

    CASES = [
        (r"Check out the \b&entire \bproject", None),
        (r"&Do \bnot \bshow this again", None),
        (r"Use \b<Ctrl+Enter> to wrap text on \bmultiple \blines.", None),
        (r"The class \bmay have a \bcounter member named: \eCount", None),
        (r"\b\eCount", None),
        (r"\b \eCount", None),
        (r"a & b <tag> c", None),
        (r"尾部孤立的 \b", None),
        (r"\ul下划线", None),
        (r"\'93引号\'94", None),
        ("没有标记的普通文本", None),
    ]
    print("=== translateprehtml 自检 ===")
    print("%-52s %-14s %s" % ("输入", "标记", "输出"))
    print("-" * 110)
    for s, _ in CASES:
        try:
            html = to_html(s)
        except Exception as exc:                      # noqa: BLE001
            html = "<异常: %s>" % exc
        print("%-52r %-14s %r" % (s[:50], sorted(find_markers(s)), html[:44]))
    print()
    print("convert =", sorted(DEFAULT_CONVERT), " other =", DEFAULT_OTHER,
          " escape =", DEFAULT_ESCAPE)
