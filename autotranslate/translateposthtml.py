# -*- coding: utf-8 -*-
r"""
translateposthtml.py —— HTML -> 词级标记（翻译**后**处理）

和 `translateprehtml.py` 互为逆操作：

    translateprehtml.to_html()   ：\b只有  ->  <strong>只有</strong>
    translateposthtml.encode()   ：<strong>只有</strong>  ->  \b只有␣

---

## 为什么必须手动补空格

`\b` 不是成对开关，它只作用于**紧跟其后的那一个 token**，而 token 以**空白**分隔。

英文天然有空格，所以没问题：

    The \bfile could not be \bopened.
      -> The <strong>file</strong> could not be <strong>opened</strong>.

但**中文不分词**，整段中文是一个 token。不补空格的话，加粗会一路"糊"到下一个空白：

    \b只有大家都帮助他，他\b才会成功
      -> <strong>只有大家都帮助他，他\b才会成功</strong>      ✗ 全加粗了，第二个 \b 也被吞掉

补上分隔空格就对了：

    \b只有 大家都帮助他，他\b才会成功␣
      -> <strong>只有</strong> 大家都帮助他，他<strong>才会成功</strong>␣   ✓

所以本编码器的核心规则就是：**每个加粗片段后面补一个空格当 token 分隔符。**

---

## 用法

命令行（主用法）：

    python translateposthtml.py "<text>"

    · text 里**没有**可处理的标签  ->  原样打印 text（一个字都不动）
    · text 里**有**可处理的标签    ->  打印编码后的文字

    $ python translateposthtml.py "普通文本"
    普通文本

    $ python translateposthtml.py "<strong>只有</strong>大家都帮助他"
    \b只有 大家都帮助他

    $ python translateposthtml.py "a &amp; b"
    a &amp; b          ← 没有标签，连实体都不反转义

    $ python translateposthtml.py "<em>斜体</em>但没 strong"
    \i斜体 但没 strong   ← <em> 也是可处理标签，会一并编码

「可处理的标签」= `MARKER_MAP` 里的那些：`<strong>` `<b>` `<em>` `<i>` `<u>`。
常态只有 `<strong>`（`translateprehtml` 默认只把 `\b` 转成 `<strong>`），
但这里把所有能编码的标签都算进来 —— 免得 `<em>` 这类漏在原样输出里，
到应用里变成可见的尖括号乱码。

Python：

    import translateposthtml

    translateposthtml.has_markup("<strong>x</strong>")   # True
    translateposthtml.has_markup("普通文本")              # False

    translateposthtml.encode("<strong>只有</strong>大家都帮助他，他<strong>才会成功</strong>")
    # '\b只有 大家都帮助他，他\b才会成功 '

    translateposthtml.encode("a &amp; b")                 # 没有标签 -> 原样
    # 'a &amp; b'

    translateposthtml.encode_lines(text)                 # 按行处理，行数 1:1

---

## 细节

0. **没有标签就原样返回**
   这是短路：只要 text 里没有可处理的标签（`<strong>` `<b>` `<em>` `<i>` `<u>`），
   连 HTML 实体都不反转义，原封不动返回。没标签的文本不该被这个工具碰。

1. **每个词单独加标记**
   `\b` 只管一个 token，所以多词内容要逐词加：
       <strong>hello world</strong>  ->  \bhello \bworld␣

2. **已有空白就不重复补**
   标签后面本来就跟着空格时不补，避免出现双空格：
       The <strong>file</strong> could  ->  The \bfile could   （不是 \bfile␣ could）

3. **HTML 实体反转义**
   `to_html` 会把 & < > 转义成实体，所以这里默认反转义回来：
       <strong>&lt;Ctrl+Enter&gt;</strong>  ->  \b<Ctrl+Enter>␣
   不想反转义就传 `unescape=False`。

4. **嵌套标签**
   由内向外反复替换，所以 `<strong><em>X</em></strong>` 也能处理：
       ->  \b\iX␣

5. **行内空白会被规整**
   内容里的连续空白/换行会折叠成单个空格（因为要给每个词单独加标记）。

## 不支持

    · 带属性的标签能识别，但属性会被丢弃（<strong class="x"> 等同于 <strong>）
    · 非加粗标签（<span> <div> 等）原样保留，不做处理
    · 内容里含字面 '<' 的（未转义的）会被当成嵌套，可能误判
"""

import html as _html
import re

# --------------------------------------------------------------------------- #
# 配置
# --------------------------------------------------------------------------- #
# HTML 标签 -> 词级标记字母
MARKER_MAP = {
    "strong": "b",
    "b": "b",
    "em": "i",
    "i": "i",
    "u": "u",
}

# 补在加粗片段后面的 token 分隔符
DELIMITER = " "

# 探测"有没有可处理的标签"。没有就直接原样返回，一个字都不动。
_MARKUP_RE = re.compile(
    r"<\s*(?:%s)\b" % "|".join(sorted((re.escape(k) for k in MARKER_MAP), key=len, reverse=True)),
    re.IGNORECASE,
)


# --------------------------------------------------------------------------- #
# 对外接口
# --------------------------------------------------------------------------- #
def has_markup(text):
    """text 里有没有可处理的加粗标签（`<strong>` 等）。

    没有就说明这条文本不需要编码，调用方应当**原样返回**，一个字都别动
    （尤其别去反转义实体 —— 那会改掉本来不该改的内容）。
    """
    if not text or not isinstance(text, str):
        return False
    return _MARKUP_RE.search(text) is not None


def encode(text, unescape=True, marker_map=None, delimiter=DELIMITER):
    """把 HTML 加粗标签编码回 `\\b` 词级标记。

    ⚠ 短路口：**没有可处理标签时直接原样返回**，连实体都不反转义。
       这是有意的 —— 没标签的文本不该被这个工具碰。

    参数:
        text        含 HTML 标签的文本（通常是翻译后的文本）
        unescape    是否把 &amp; &lt; &gt; 等实体反转义回来，默认 True
                    （只在"有标签"那条路径上生效）
        marker_map  标签 -> 标记字母的映射，默认 MARKER_MAP
        delimiter   补在加粗片段后面的分隔符，默认一个空格

    返回:
        编码后的文本；没有标签时就是传入的 text 本身。

    例:
        encode("<strong>只有</strong>大家都帮助他，他<strong>才会成功</strong>")
        # '\\b只有 大家都帮助他，他\\b才会成功 '

        encode("a &amp; b")      # 没有标签 -> 原样，不反转义
        # 'a &amp; b'
    """
    if text is None:
        return ""
    if not isinstance(text, str):
        text = str(text)

    # ---- 短路口：没有标签，原样返回，一个字都不动 ----
    if not has_markup(text):
        return text

    tag_re = _tag_re(marker_map or MARKER_MAP)

    # 由内向外逐层剥：每轮只处理"内容里没有别的标签"的最内层
    # 轮数上限 = 标签层数上限，防止极端输入下转不动
    limit = 64
    for _ in range(limit):
        new = _encode_pass(text, tag_re, marker_map or MARKER_MAP, delimiter)
        if new == text:
            break
        text = new

    if unescape:
        text = _html.unescape(text)
    return text


def encode_lines(text, **kw):
    """按行处理，空行原样保留（行数严格 1:1，避免翻译对齐错位）。"""
    out = []
    for line in text.split("\n"):
        out.append(encode(line, **kw) if line.strip() else line)
    return "\n".join(out)


# --------------------------------------------------------------------------- #
# 内部
# --------------------------------------------------------------------------- #
def _tag_re(marker_map):
    return re.compile(
        r"<(?P<tag>%s)(?:\s[^>]*)?>(?P<content>[^<]*)</(?P=tag)\s*>"
        % "|".join(sorted((re.escape(k) for k in marker_map), key=len, reverse=True)),
        re.IGNORECASE,
    )


def _encode_pass(text, tag_re, marker_map, delimiter):
    """单轮替换：把所有"最内层"的标签转成词级标记。"""
    out = []
    pos = 0
    for m in tag_re.finditer(text):
        out.append(text[pos:m.start()])
        letter = marker_map[m.group("tag").lower()]
        content = m.group("content")
        words = content.split()

        if not words:
            # 空的加粗片段（如 <strong></strong>）：没有内容可标记，原样留着
            out.append(content)
        else:
            # \b 只作用于一个 token -> 每个词前面都要加一个标记
            piece = "".join("\\%s%s%s" % (letter, w, delimiter) for w in words)
            # 标签后面本来就跟着空白，就用那个空白当分隔符，别补出双空格。
            # 注意：串尾不算（后面没字符），分隔符要留着，跟 \b才会成功␣ 一致。
            nxt = text[m.end():m.end() + 1]
            if nxt.isspace():
                piece = piece[:-len(delimiter)] if delimiter else piece
            out.append(piece)

        pos = m.end()
    out.append(text[pos:])
    return "".join(out)


# --------------------------------------------------------------------------- #
# 自检 / 命令行
# --------------------------------------------------------------------------- #
if __name__ == "__main__":
    import sys

    if "--selftest" in sys.argv:
        CASES = [
            # (输入, 期望输出, 说明)
            ("<strong>只有</strong>大家都帮助他，他<strong>才会成功</strong>",
             "\\b只有 大家都帮助他，他\\b才会成功 ",
             "中文：补空格界定 token"),
            ("The <strong>file</strong> could not be <strong>opened</strong>.",
             "The \\bfile could not be \\bopened .",
             "英文：后面已有空白就不补；后面是句号则补"),
            ("<strong>hello world</strong>",
             "\\bhello \\bworld ",
             "多词：每个词单独加标记"),
            ("<strong>&lt;Ctrl+Enter&gt;</strong>",
             "\\b<Ctrl+Enter> ",
             "实体反转义"),
            ("<strong><em>X</em></strong>",
             "\\b\\iX ",
             "嵌套标签：由内向外"),
            ("没有标签的普通文本",
             "没有标签的普通文本",
             "无标签：原样"),
            ("a &amp; b",
             "a &amp; b",
             "无标签：连实体都不反转义"),
            ("中文 &lt;tag&gt; 但没有加粗",
             "中文 &lt;tag&gt; 但没有加粗",
             "无标签：其它标签也不动"),
            ("<em>斜体</em>但没 strong",
             "\\i斜体 但没 strong",
             "<em> 也算可处理标签，一并编码（避免漏成尖括号乱码）"),
            ("<STRONG>大写标签</STRONG>",
             "\\b大写标签 ",
             "标签大小写不敏感"),
            ('<strong class="hl">带属性</strong>',
             "\\b带属性 ",
             "带属性标签"),
            ("<strong></strong>",
             "",
             "空内容"),
            ("前缀<strong>打开</strong>。后缀",
             "前缀\\b打开 。后缀",
             "后面是标点：照样补分隔符"),
        ]
        print("=== translateposthtml 自检 ===")
        print("%-50s %-8s %s" % ("输入", "结果", "输出"))
        print("-" * 100)
        bad = 0
        for src, want, note in CASES:
            got = encode(src)
            ok = (got == want)
            bad += (not ok)
            print("  [%s] %-44r %-6s %r" % ("OK " if ok else "FAIL", src[:42],
                                           "OK" if ok else "错", got[:40]))
            if not ok:
                print("           期望: %r" % want)
        print()
        print("自检: %d/%d 通过" % (len(CASES) - bad, len(CASES)))
        sys.exit(1 if bad else 0)

    if not sys.argv[1:]:
        print("用法:")
        print("  python translateposthtml.py \"<text>\"")
        print("  python translateposthtml.py --selftest")
        print()
        print("看 text 里有没有可处理的标签（<strong> <b> <em> <i> <u>）：")
        print("  没有 -> 原样打印 text，一个字都不动（连 HTML 实体也不反转义）")
        print("  有   -> 打印编码后的文字（HTML 标签 -> \\b 等词级标记）")
        sys.exit(0)

    # 主用法：把所有位置参数当**一句话**（多个参数用空格拼回，方便不加引号）
    text = " ".join(sys.argv[1:])
    print(encode(text))
