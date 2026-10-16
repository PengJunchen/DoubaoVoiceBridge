from __future__ import annotations

import json
import math
import os
from functools import lru_cache

from PIL import Image, ImageDraw, ImageFont


OUT = os.path.dirname(os.path.abspath(__file__))
FONT_REGULAR = "/System/Library/Fonts/Hiragino Sans GB.ttc"
FONT_MEDIUM = "/System/Library/Fonts/STHeiti Medium.ttc"
FONT_SYMBOL = "/System/Library/Fonts/SFNS.ttf"

THEMES = {
    "A": {
        "name": "雾蓝浅色",
        "mood": "清透、克制、容易融入 macOS 日常窗口",
        "canvas": "#EFF3F4",
        "surface": "#FFFFFF",
        "text": "#293842",
        "muted": "#536874",
        "accent": "#53778C",
        "separator": "#C7D3D9",
        "icon_kind": "mist",
        "icon_base": "#C7D3D9",
        "icon_ink": "#53778C",
        "recommendation": "推荐。浅色桌面环境中最容易读，蓝色集中在快捷键、主按钮与图标上。",
    },
    "B": {
        "name": "深灰蓝",
        "mood": "沉静、专注、具有清晰的深色工具感",
        "canvas": "#1F2A32",
        "surface": "#2B3943",
        "text": "#F3F5F3",
        "muted": "#C0C9CE",
        "accent": "#96B3C1",
        "separator": "#465861",
        "icon_kind": "slate",
        "icon_base": "#2B3943",
        "icon_ink": "#96B3C1",
        "recommendation": "深色方向。图标与主操作用浅雾蓝提亮，界面整体保持石板灰蓝。",
    },
    "C": {
        "name": "暖灰蓝",
        "mood": "温和、安定、接近纸感的暖中性色",
        "canvas": "#EAE8E1",
        "surface": "#F8F7F2",
        "text": "#31383C",
        "muted": "#5D686B",
        "accent": "#506D7D",
        "separator": "#C6C3BB",
        "icon_kind": "warm",
        "icon_base": "#F8F7F2",
        "icon_ink": "#506D7D",
        "recommendation": "暖色方向。灰蓝只做操作与键帽标记，表面带有柔和的暖灰底色。",
    },
}

ROLE_LABELS = {
    "canvas": "窗口外层 / 背景",
    "surface": "窗口表面",
    "text": "主要文字",
    "muted": "说明文字",
    "accent": "操作 / 快捷键 / 图标",
    "separator": "分隔线 / 边界",
}


@lru_cache(maxsize=64)
def font(size: int, weight: str = "regular"):
    path = FONT_MEDIUM if weight == "bold" and os.path.exists(FONT_MEDIUM) else FONT_REGULAR
    if not os.path.exists(path):
        path = FONT_SYMBOL
    try:
        return ImageFont.truetype(path, max(1, int(size)))
    except OSError:
        return ImageFont.load_default()


def rgb(hex_color: str):
    value = hex_color.lstrip("#")
    return tuple(int(value[i : i + 2], 16) for i in (0, 2, 4))


def lum(hex_color: str):
    values = []
    for channel in rgb(hex_color):
        c = channel / 255
        values.append(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4)
    return 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2]


def contrast(a: str, b: str):
    light, dark = sorted((lum(a), lum(b)), reverse=True)
    return round((light + 0.05) / (dark + 0.05), 2)


def text(draw, xy, value, size, color, weight="regular", anchor="lt"):
    draw.text(xy, value, fill=color, font=font(size, weight), anchor=anchor)


def center_text(draw, box, value, size, color, weight="regular"):
    x1, y1, x2, y2 = box
    draw.text(((x1 + x2) / 2, (y1 + y2) / 2), value, fill=color,
              font=font(size, weight), anchor="mm")


def rr(draw, box, radius, fill, outline=None, width=1):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def draw_icon(theme, size=1024):
    s = size / 512
    im = Image.new("RGB", (size, size), theme["icon_base"])
    d = ImageDraw.Draw(im)
    accent = theme["icon_ink"]
    bg = theme["icon_base"]
    kind = theme["icon_kind"]

    def box(v):
        return tuple(int(round(x * s)) for x in v)

    def width(v):
        return max(1, int(round(v * s)))

    radius = int(112 * s)
    d.rounded_rectangle(box((0, 0, 512, 512)), radius=radius, fill=bg,
                         outline=theme["separator"], width=width(3))

    if kind == "mist":
        # A quiet microphone silhouette with broad, legible voice arcs.
        d.ellipse(box((64, 64, 448, 448)), fill=theme["surface"])
        d.rounded_rectangle(box((214, 120, 298, 310)), radius=int(42 * s), fill=accent)
        d.arc(box((168, 210, 344, 378)), start=0, end=180, fill=accent, width=width(22))
        d.line([box((256, 345,))[0], box((256, 345))[1], box((256, 392))[0], box((256, 392))[1]], fill=accent, width=width(22))
        d.line([box((198, 400))[0], box((198, 400))[1], box((314, 400))[0], box((314, 400))[1]], fill=accent, width=width(22))
        d.arc(box((112, 172, 194, 326)), start=100, end=260, fill=accent, width=width(18))
        d.arc(box((318, 172, 400, 326)), start=280, end=80, fill=accent, width=width(18))
    elif kind == "slate":
        # Voice signal crossing a remote display; stronger technical direction.
        light = theme["accent"]
        d.rounded_rectangle(box((244, 138, 424, 316)), radius=int(26 * s), outline=light, width=width(20))
        d.line([box((334, 318))[0], box((334, 318))[1], box((334, 360))[0], box((334, 360))[1]], fill=light, width=width(18))
        d.line([box((284, 365))[0], box((284, 365))[1], box((384, 365))[0], box((384, 365))[1]], fill=light, width=width(18))
        d.rounded_rectangle(box((92, 168, 178, 326)), radius=int(42 * s), fill=light)
        d.arc(box((132, 220, 224, 340)), start=0, end=180, fill=light, width=width(18))
        d.line([box((178, 276))[0], box((178, 276))[1], box((222, 276))[0], box((222, 276))[1]], fill=light, width=width(15))
        d.ellipse(box((198, 265, 218, 285)), fill=light)
        d.line([box((214, 258))[0], box((214, 258))[1], box((232, 242))[0], box((232, 242))[1]], fill=light, width=width(13))
    else:
        # One soft voice mark over an Option key cap: a compact shortcut cue.
        d.rounded_rectangle(box((72, 332, 440, 420)), radius=int(28 * s), fill=theme["surface"], outline=theme["separator"], width=width(8))
        d.rounded_rectangle(box((203, 94, 309, 250)), radius=int(52 * s), fill=accent)
        d.arc(box((159, 138, 353, 310)), start=0, end=180, fill=accent, width=width(20))
        d.line([box((256, 310))[0], box((256, 310))[1], box((256, 325))[0], box((256, 325))[1]], fill=accent, width=width(19))
        # A simple forked mark keeps the keycap recognizable without font dependencies.
        d.line([box((256, 394))[0], box((256, 394))[1], box((256, 369))[0], box((256, 369))[1],
                box((228, 342))[0], box((228, 342))[1]], fill=accent, width=width(12), joint="curve")
        d.line([box((256, 369))[0], box((256, 369))[1], box((284, 342))[0], box((284, 342))[1]], fill=accent, width=width(12))
        d.line([box((215, 342))[0], box((215, 342))[1], box((228, 342))[0], box((228, 342))[1]], fill=accent, width=width(12))
        d.line([box((284, 342))[0], box((284, 342))[1], box((297, 342))[0], box((297, 342))[1]], fill=accent, width=width(12))

    return im


def svg_for_icon(theme):
    kind = theme["icon_kind"]
    base, accent, surface, separator = (theme[k] for k in ("icon_base", "icon_ink", "surface", "separator"))
    if kind == "mist":
        motif = f'''<circle cx="256" cy="256" r="192" fill="{surface}"/>
<rect x="214" y="120" width="84" height="190" rx="42" fill="{accent}"/>
<path d="M168 294a88 88 0 0 0 176 0" fill="none" stroke="{accent}" stroke-width="22" stroke-linecap="round"/>
<path d="M256 345v47m-58 8h116" fill="none" stroke="{accent}" stroke-width="22" stroke-linecap="round"/>
<path d="M194 194a88 88 0 0 0 0 112m124-112a88 88 0 0 1 0 112" fill="none" stroke="{accent}" stroke-width="18" stroke-linecap="round"/>'''
    elif kind == "slate":
        motif = f'''<rect x="244" y="138" width="180" height="178" rx="26" fill="none" stroke="{accent}" stroke-width="20"/>
<path d="M334 318v42m-50 5h100" fill="none" stroke="{accent}" stroke-width="18" stroke-linecap="round"/>
<rect x="92" y="168" width="86" height="158" rx="42" fill="{accent}"/>
<path d="M132 280a46 46 0 0 0 92 0h-46m20-18 22 14-22 14" fill="none" stroke="{accent}" stroke-width="18" stroke-linecap="round" stroke-linejoin="round"/>'''
    else:
        motif = f'''<rect x="72" y="300" width="368" height="114" rx="34" fill="{surface}" stroke="{separator}" stroke-width="8"/>
<rect x="203" y="94" width="106" height="156" rx="52" fill="{accent}"/>
<path d="M159 224a97 86 0 0 0 194 0m-97 86v15" fill="none" stroke="{accent}" stroke-width="20" stroke-linecap="round"/>
<path d="M256 394v-25l-28-27m28 27 28-27m-41 0h-13m54 0h13" fill="none" stroke="{accent}" stroke-width="12" stroke-linecap="round" stroke-linejoin="round"/>'''
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 512 512">
<rect width="512" height="512" rx="112" fill="{base}" stroke="{separator}" stroke-width="3"/>
{motif}
</svg>
'''


def draw_keycap(draw, x, y, width, height, theme, size):
    d = theme
    fill = d["accent"] if d["icon_kind"] == "warm" else d["surface"]
    ink = d["canvas"] if d["icon_kind"] == "warm" else d["accent"]
    outline = d["accent"]
    rr(draw, (x, y, x + width, y + height), int(height * 0.24), fill, outline=outline, width=max(1, int(size * 0.018)))
    center_text(draw, (x, y - size * 0.005, x + width, y + height), "Option", int(size * 0.43), ink, "bold")


def draw_usage(draw, x, y, theme, size, for_menu=False):
    t = theme
    color = t["text"]
    f = font(size, "bold")
    prefix = "在 UU 中按住 左 "
    suffix = " 说话"
    prefix_w = f.getlength(prefix)
    suffix_w = f.getlength(suffix)
    key_w = int(size * 2.23)
    key_h = int(size * 1.28)
    total = prefix_w + key_w + suffix_w
    draw.text((x, y + int(size * 0.13)), prefix, fill=color, font=f, anchor="lt")
    key_y = y + int(size * 0.02)
    draw_keycap(draw, x + prefix_w, key_y, key_w, key_h, t, size)
    draw.text((x + prefix_w + key_w, y + int(size * 0.13)), suffix, fill=color, font=f, anchor="lt")
    return total, max(size, key_h)


def draw_button(draw, box, label, theme, primary=False, size=21):
    t = theme
    if primary:
        fill = t["accent"]
        label_color = t["canvas"] if t["icon_kind"] == "slate" else "#FFFFFF"
        outline = t["accent"]
    else:
        fill = t["canvas"]
        label_color = t["text"]
        outline = t["separator"]
    rr(draw, box, int((box[3] - box[1]) * 0.22), fill, outline=outline, width=1)
    center_text(draw, box, label, size, label_color, "bold" if primary else "regular")


def draw_app_window(im, box, theme, scale=1.0):
    x, y, w, h = box
    d = ImageDraw.Draw(im)
    t = theme
    radius = int(24 * scale)
    # soft floating window shadow
    if im.mode == "RGBA":
        shadow = Image.new("RGBA", im.size, (0, 0, 0, 0))
        sd = ImageDraw.Draw(shadow)
        sd.rounded_rectangle((x + 2, y + int(10 * scale), x + w + 2, y + h + int(10 * scale)),
                             radius=radius, fill=(24, 37, 45, 42 if t["icon_kind"] != "slate" else 100))
        im.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(int(12 * scale))))
        d = ImageDraw.Draw(im)
    rr(d, (x, y, x + w, y + h), radius, t["surface"], outline=t["separator"], width=max(1, int(scale)))
    title_h = int(64 * scale)
    d.line((x, y + title_h, x + w, y + title_h), fill=t["separator"], width=max(1, int(scale)))
    # macOS traffic lights, deliberately softened to keep attention on dictation.
    light_size = int(14 * scale)
    lights = ["#D77E7A", "#D7B36A", "#7EAA89"]
    for i, c in enumerate(lights):
        cx = x + int(26 * scale) + i * int(25 * scale)
        cy = y + int(31 * scale)
        d.ellipse((cx - light_size // 2, cy - light_size // 2, cx + light_size // 2, cy + light_size // 2), fill=c)
    text(d, (x + int(114 * scale), y + int(17 * scale)), "远控听写设置", int(20 * scale), t["muted"], "bold")

    left = x + int(58 * scale)
    top = y + int(94 * scale)
    icon_size = int(64 * scale)
    icon = draw_icon(t, max(64, int(icon_size * 2))).resize((icon_size, icon_size), Image.Resampling.LANCZOS)
    if im.mode == "RGBA":
        im.alpha_composite(icon.convert("RGBA"), (left, top))
    else:
        im.paste(icon, (left, top))
    d = ImageDraw.Draw(im)
    text(d, (left + icon_size + int(18 * scale), top + int(10 * scale)), "远控听写", int(30 * scale), t["text"], "bold")

    usage_y = y + int(220 * scale)
    if t["icon_kind"] == "mist":
        rr(d, (x + int(36 * scale), usage_y - int(22 * scale), x + w - int(36 * scale), usage_y + int(112 * scale)),
           int(20 * scale), t["canvas"])
        marker_x = x + int(59 * scale)
        cy = usage_y + int(42 * scale)
        d.ellipse((marker_x, cy, marker_x + int(13 * scale), cy + int(13 * scale)), fill=t["accent"])
        usage_x = x + int(90 * scale)
    elif t["icon_kind"] == "slate":
        d.rounded_rectangle((x + int(48 * scale), usage_y - int(15 * scale), x + int(54 * scale), usage_y + int(97 * scale)),
                            radius=int(4 * scale), fill=t["accent"])
        usage_x = x + int(82 * scale)
    else:
        usage_x = x + int(58 * scale)
    usage_size = int(39 * scale)
    draw_usage(d, usage_x, usage_y, t, usage_size)

    detail_y = y + int(360 * scale)
    detail = "松开按键结束识别，文字自动粘贴到远端输入框。"
    text(d, (left, detail_y), detail, int(22 * scale), t["text"], "regular")

    boundary_y = y + int(470 * scale)
    text(d, (left, boundary_y), "先点选远端输入框。粘贴完成后，自行发送消息。", int(20 * scale), t["muted"], "regular")

    permission_y = y + int(570 * scale)
    # A compact check marker plus explicit permission state; text carries the meaning.
    d.ellipse((left, permission_y + int(3 * scale), left + int(20 * scale), permission_y + int(23 * scale)), fill=t["accent"])
    d.line((left + int(5 * scale), permission_y + int(13 * scale), left + int(9 * scale), permission_y + int(17 * scale),
            left + int(16 * scale), permission_y + int(8 * scale)), fill=t["surface"], width=max(1, int(2.5 * scale)))
    text(d, (left + int(30 * scale), permission_y), "辅助功能已授权 · 输入监控已授权", int(18 * scale), t["muted"])
    draw_button(d, (x + w - int(250 * scale), permission_y - int(11 * scale), x + w - int(58 * scale), permission_y + int(40 * scale)),
                "检查权限…", t, primary=False, size=int(18 * scale))

    advanced_y = y + int(674 * scale)
    draw_button(d, (left, advanced_y, left + int(340 * scale), advanced_y + int(58 * scale)),
                "更改按键与高级设置…", t, primary=False, size=int(19 * scale))

    footer_top = y + h - int(100 * scale)
    d.line((x + int(36 * scale), footer_top, x + w - int(36 * scale), footer_top), fill=t["separator"], width=max(1, int(scale)))
    text(d, (left, footer_top + int(36 * scale)), "版本 0.1.0 · 关闭窗口后在菜单栏运行", int(16 * scale), t["muted"])
    draw_button(d, (x + w - int(274 * scale), footer_top + int(19 * scale), x + w - int(58 * scale), footer_top + int(76 * scale)),
                "保存并启用", t, primary=True, size=int(20 * scale))
    return im


def draw_menu(im, box, theme, scale=1.0):
    x, y, w, h = box
    d = ImageDraw.Draw(im)
    t = theme
    # surrounding menu bar cue
    bar_h = int(42 * scale)
    bar = t["surface"]
    rr(d, (x, y, x + w, y + bar_h), int(10 * scale), bar, outline=t["separator"], width=max(1, int(scale)))
    # The redesigned app icon also serves as the menu bar status mark.
    mini_size = max(8, int(25 * scale))
    mini_icon = draw_icon(t, max(64, mini_size * 3)).resize((mini_size, mini_size), Image.Resampling.LANCZOS)
    if im.mode == "RGBA":
        im.alpha_composite(mini_icon.convert("RGBA"), (x + int(12 * scale), y + int(8 * scale)))
    else:
        im.paste(mini_icon, (x + int(12 * scale), y + int(8 * scale)))
    d = ImageDraw.Draw(im)
    text(d, (x + int(46 * scale), y + int(8 * scale)), "远控听写 · 已启用", int(17 * scale), t["text"], "bold")
    status = "菜单栏状态"
    text(d, (x + w - int(16 * scale), y + int(8 * scale)), status, int(15 * scale), t["muted"], anchor="rt")

    py = y + bar_h + int(12 * scale)
    pop_h = h - bar_h - int(12 * scale)
    rr(d, (x, py, x + w, py + pop_h), int(16 * scale), t["surface"], outline=t["separator"], width=max(1, int(scale)))
    item_left = x + int(22 * scale)
    top_line = py + int(18 * scale)
    d.ellipse((item_left, top_line + int(7 * scale), item_left + int(10 * scale), top_line + int(17 * scale)), fill=t["accent"])
    text(d, (item_left + int(22 * scale), top_line), "远控听写", int(17 * scale), t["text"], "bold")
    text(d, (x + w - int(22 * scale), top_line), "已启用", int(15 * scale), t["muted"], anchor="rt")
    d.line((x + int(16 * scale), py + int(54 * scale), x + w - int(16 * scale), py + int(54 * scale)), fill=t["separator"], width=max(1, int(scale)))

    action_y = py + int(70 * scale)
    rr(d, (x + int(12 * scale), action_y, x + w - int(12 * scale), action_y + int(58 * scale)),
       int(10 * scale), t["canvas"])
    text(d, (x + int(28 * scale), action_y + int(15 * scale)), "在 UU 中按住 左 Option 说话", int(17 * scale), t["text"], "bold")
    rows = ["打开设置…", "更多", "退出远控听写"]
    row_h = int(49 * scale)
    for i, label in enumerate(rows):
        ry = action_y + int(70 * scale) + i * row_h
        text(d, (x + int(28 * scale), ry), label, int(17 * scale), t["text"], "regular")
        if i == 1:
            cx = x + w - int(30 * scale)
            cy = ry + int(13 * scale)
            d.line((cx - int(4 * scale), cy, cx, cy + int(5 * scale), cx - int(4 * scale), cy + int(10 * scale)),
                   fill=t["muted"], width=max(1, int(2 * scale)))
        if i == 0:
            d.line((x + int(16 * scale), ry + row_h - int(6 * scale), x + w - int(16 * scale), ry + row_h - int(6 * scale)), fill=t["separator"], width=max(1, int(scale)))
    return im


def palette_roles(theme):
    return [
        ("canvas", theme["canvas"], ROLE_LABELS["canvas"]),
        ("surface", theme["surface"], ROLE_LABELS["surface"]),
        ("text", theme["text"], ROLE_LABELS["text"]),
        ("muted", theme["muted"], ROLE_LABELS["muted"]),
        ("accent", theme["accent"], ROLE_LABELS["accent"]),
        ("separator", theme["separator"], ROLE_LABELS["separator"]),
    ]


def draw_swatches(draw, x, y, width, height, theme, scale=1.0, cols=6, gap=12):
    roles = palette_roles(theme)
    cell_w = (width - gap * (cols - 1)) / cols
    for i, (role, color, label) in enumerate(roles):
        cx = x + i * (cell_w + gap)
        # Give every swatch a thin edge so pale tokens remain visible.
        rr(draw, (cx, y, cx + cell_w, y + height), int(10 * scale), color, outline=theme["separator"], width=max(1, int(scale)))
        dark_ink = "#202B34"
        light_ink = "#F7F8F7"
        fg = light_ink if contrast(light_ink, color) >= contrast(dark_ink, color) else dark_ink
        text(draw, (cx + int(11 * scale), y + int(9 * scale)), role.upper(), int(14 * scale), fg, "bold")
        text(draw, (cx + int(11 * scale), y + int(31 * scale)), color, int(15 * scale), fg, "regular")
        text(draw, (cx + int(11 * scale), y + height - int(29 * scale)), label, int(12 * scale), fg, "regular")


def draw_proposal(code, theme):
    W, H = 2000, 1510
    im = Image.new("RGBA", (W, H), rgb(theme["canvas"]) + (255,))
    d = ImageDraw.Draw(im)
    text(d, (74, 46), f"方案 {code}  ·  {theme['name']}", 42, theme["text"], "bold")
    badge = (1475, 45, 1925, 96)
    rr(d, badge, 24, theme["surface"], outline=theme["separator"], width=1)
    center_text(d, badge, "静态提案  ·  选择后再实施", 19, theme["muted"], "bold")
    text(d, (76, 112), theme["mood"], 20, theme["muted"])

    app_box = (70, 160, 1120, 1040)
    draw_app_window(im, app_box, theme, scale=1.0)

    icon = draw_icon(theme, 1024)
    icon_x, icon_y, icon_size = 1392, 171, 350
    im.alpha_composite(icon.convert("RGBA").resize((icon_size, icon_size), Image.Resampling.LANCZOS), (icon_x, icon_y))
    d = ImageDraw.Draw(im)
    text(d, (icon_x + icon_size + 28, icon_y + 18), "应用图标", 22, theme["muted"], "bold")
    text(d, (icon_x + icon_size + 28, icon_y + 51), "矢量概念", 17, theme["muted"])
    icon32 = icon.resize((32, 32), Image.Resampling.LANCZOS)
    icon16 = icon.resize((16, 16), Image.Resampling.LANCZOS)
    im.paste(icon32, (icon_x + int(icon_size * 0.28), icon_y + icon_size + 24))
    im.paste(icon16, (icon_x + int(icon_size * 0.62), icon_y + icon_size + 32))
    text(d, (icon_x + int(icon_size * 0.28) + 42, icon_y + icon_size + 28), "32 px", 16, theme["muted"])
    text(d, (icon_x + int(icon_size * 0.62) + 28, icon_y + icon_size + 31), "16 px", 16, theme["muted"])

    menu_box = (1230, 673, 700, 432)
    draw_menu(im, menu_box, theme, scale=1.0)
    d = ImageDraw.Draw(im)
    text(d, (1230, 1127), "菜单栏状态 / 打开设置 / 更多 / 退出", 18, theme["muted"])

    palette_y = 1231
    text(d, (74, palette_y - 38), "六个界面色角色", 18, theme["muted"], "bold")
    draw_swatches(d, 74, palette_y, 1851, 115, theme, scale=1.0, cols=6, gap=12)
    foot = "快捷键为左 Option 示例；录制新按键后，界面文案会随当前设置更新。"
    text(d, (76, 1393), foot, 16, theme["muted"])
    return im.convert("RGB")


def draw_overview(themes):
    W, H = 2700, 1530
    board = Image.new("RGBA", (W, H), (231, 236, 238, 255))
    d = ImageDraw.Draw(board)
    text(d, (70, 35), "莫兰迪蓝 · 远控听写视觉提案", 46, "#26333B", "bold")
    text(d, (72, 96), "同一功能层级，三种色温与图标方向。当前为静态方案，待用户选择后再实施。", 22, "#52636D")
    card_w, card_h, gap = 830, 1340, 36
    top = 156
    for idx, code in enumerate(("A", "B", "C")):
        theme = themes[code]
        x = 56 + idx * (card_w + gap)
        y = top
        # Each scheme has its own base surface while the outer board remains neutral.
        rr(d, (x, y, x + card_w, y + card_h), 24, theme["canvas"], outline=theme["separator"], width=2)
        text(d, (x + 24, y + 19), f"{code} · {theme['name']}", 28, theme["text"], "bold")
        text(d, (x + 24, y + 61), theme["mood"], 16, theme["muted"])

        icon = draw_icon(theme, 512)
        small = icon.resize((146, 146), Image.Resampling.LANCZOS)
        board.alpha_composite(small.convert("RGBA"), (x + 26, y + 103))
        icon32 = icon.resize((32, 32), Image.Resampling.LANCZOS)
        icon16 = icon.resize((16, 16), Image.Resampling.LANCZOS)
        board.paste(icon32, (x + 190, y + 144))
        board.paste(icon16, (x + 284, y + 152))
        text(d, (x + 232, y + 148), "32 px", 14, theme["muted"])
        text(d, (x + 310, y + 152), "16 px", 14, theme["muted"])

        # A scaled, still legible window preview carries the actual copy and hierarchy.
        app_x, app_y = x + 22, y + 275
        app_w, app_h = card_w - 44, 720
        # Use a temporary transparent canvas and scale the detailed window as one native view.
        sample = Image.new("RGBA", (1120, 1040), (0, 0, 0, 0))
        draw_app_window(sample, (0, 0, 1120, 1040), theme, scale=1.0)
        resized = sample.resize((app_w, app_h), Image.Resampling.LANCZOS)
        board.alpha_composite(resized, (app_x, app_y))

        menu_x, menu_y = x + 24, y + 1010
        draw_menu(board, (menu_x, menu_y, card_w - 48, 200), theme, scale=0.48)
        draw_swatches(d, x + 24, y + 1242, card_w - 48, 72, theme, scale=0.72, cols=6, gap=6)
    return board.convert("RGB")


def write_palette(themes):
    data = {
        "title": "莫兰迪蓝远控听写静态提案",
        "date": "2026-10-16",
        "status": "静态视觉原型；尚未实施或做真实应用验证",
        "example_shortcut": "左 Option（显示示例；实际文案随录制按键更新）",
        "recommended": "A",
        "options": {},
    }
    for code, t in themes.items():
        data["options"][code] = {
            "name": t["name"],
            "mood": t["mood"],
            "recommendation": t["recommendation"],
            "colors": {role: {"hex": color, "use": label} for role, color, label in palette_roles(t)},
            "contrast_ratio": {
                "primary_text_on_surface": contrast(t["text"], t["surface"]),
                "secondary_text_on_surface": contrast(t["muted"], t["surface"]),
                "accent_on_surface": contrast(t["accent"], t["surface"]),
                "button_label_on_accent": contrast(t["canvas"] if code == "B" else "#FFFFFF", t["accent"]),
            },
            "notes": "主文字与次文字按 WCAG AA 正文 4.5:1 检查；快捷键和图标作为大号或图形元素按 3:1 检查。分隔线只表达分组，不承担独立状态含义。",
        }
    with open(os.path.join(OUT, "palette.json"), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

    lines = [
        "# 莫兰迪蓝配色提案",
        "",
        "状态：静态视觉原型，供用户评审。没有改动生产界面，也没有进行真实 UI 或功能验证。",
        "",
        "快捷键以左 Option 作示例；设置页实际文案会随新录制的按键更新。",
        "",
        "建议优先评审 A。它在浅色 macOS 窗口里最清晰，雾蓝集中在主操作、快捷键和图标上，保留原生留白。B 提供安静的深色工具感；C 用暖灰减少冷感，同时保留足够深的蓝灰操作色。",
        "",
    ]
    for code, t in themes.items():
        r = data["options"][code]["contrast_ratio"]
        lines.extend([
            f"## {code} · {t['name']}",
            "",
            f"{t['mood']}。{t['recommendation']}",
            "",
            "| 角色 | 色值 | 用途 |",
            "|---|---|---|",
        ])
        for role, color, label in palette_roles(t):
            lines.append(f"| {role} | `{color}` | {label} |")
        lines.extend([
            "",
            f"对比度：正文 `{r['primary_text_on_surface']}:1`；说明文字 `{r['secondary_text_on_surface']}:1`；强调色与表面 `{r['accent_on_surface']}:1`；主按钮文字 `{r['button_label_on_accent']}:1`。正文与说明文字目标为 WCAG AA 4.5:1，图形与大字目标为 3:1。",
            "",
        ])
    with open(os.path.join(OUT, "palette.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def main():
    os.makedirs(OUT, exist_ok=True)
    write_palette(THEMES)
    for code, theme in THEMES.items():
        proposal = draw_proposal(code, theme)
        proposal.save(os.path.join(OUT, f"proposal-{code}-{theme['name']}.png"), optimize=True)
        draw_icon(theme, 1024).save(os.path.join(OUT, f"icon-{code}.png"), optimize=True)
        with open(os.path.join(OUT, f"icon-{code}.svg"), "w", encoding="utf-8") as f:
            f.write(svg_for_icon(theme))
    draw_overview(THEMES).save(os.path.join(OUT, "overview.png"), optimize=True)
    print("Rendered overview, three proposals, icon PNG/SVG sources, and palette documentation.")


if __name__ == "__main__":
    from PIL import ImageFilter
    main()
