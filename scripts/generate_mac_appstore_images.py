#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parents[1]
INPUT_DIR = ROOT / "appstore" / "screenshots" / "mac"
OUTPUT_DIR = ROOT / "appstore" / "appstore_assets" / "mac"

W, H = 1280, 800


def load_font(locale: str, size: int, weight: str = "regular") -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    cjk_regular = [
        Path("/System/Library/Fonts/Hiragino Sans GB.ttc"),
        Path("/Library/Fonts/Arial Unicode.ttf"),
    ]
    en_regular = [
        Path("/System/Library/Fonts/SFNS.ttf"),
        Path("/System/Library/Fonts/HelveticaNeue.ttc"),
        Path("/System/Library/Fonts/Helvetica.ttc"),
        Path("/Library/Fonts/Arial.ttf"),
    ]

    cjk_bold = [
        Path("/System/Library/Fonts/STHeiti Medium.ttc"),
        Path("/System/Library/Fonts/Hiragino Sans GB.ttc"),
        Path("/Library/Fonts/Arial Unicode.ttf"),
    ]
    en_bold = [
        Path("/System/Library/Fonts/SFNS.ttf"),
        Path("/System/Library/Fonts/HelveticaNeue.ttc"),
        Path("/Library/Fonts/Arial Bold.ttf"),
    ]

    use_cjk = locale in {"zh-Hans", "zh-Hant", "ja"}
    candidates = cjk_bold if use_cjk and weight != "regular" else cjk_regular if use_cjk else en_bold if weight != "regular" else en_regular
    for path in candidates:
        if path.exists():
            try:
                return ImageFont.truetype(str(path), size=size)
            except OSError:
                continue
    return ImageFont.load_default()


def lerp_color(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return (
        int(a[0] + (b[0] - a[0]) * t),
        int(a[1] + (b[1] - a[1]) * t),
        int(a[2] + (b[2] - a[2]) * t),
    )


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size[0], size[1]), radius=radius, fill=255)
    return mask


def wrap_text(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont, max_width: int) -> list[str]:
    if " " in text:
        lines: list[str] = []
        words = text.split()
        current = ""
        for word in words:
            candidate = word if not current else f"{current} {word}"
            width = draw.textbbox((0, 0), candidate, font=font)[2]
            if width <= max_width:
                current = candidate
            else:
                if current:
                    lines.append(current)
                current = word
        if current:
            lines.append(current)
        return lines

    lines = []
    current = ""
    for ch in text:
        candidate = current + ch
        width = draw.textbbox((0, 0), candidate, font=font)[2]
        if width <= max_width or not current:
            current = candidate
        else:
            lines.append(current)
            current = ch
    if current:
        lines.append(current)
    return lines


def add_glow(base: Image.Image, xy: tuple[int, int], size: tuple[int, int], color: tuple[int, int, int], alpha: int) -> None:
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    x, y = xy
    w, h = size
    draw.ellipse((x, y, x + w, y + h), fill=(*color, alpha))
    base.alpha_composite(layer.filter(ImageFilter.GaussianBlur(72)))


def build_background(top: tuple[int, int, int], bottom: tuple[int, int, int], accent: tuple[int, int, int]) -> Image.Image:
    bg = Image.new("RGBA", (W, H), (255, 255, 255, 255))
    draw = ImageDraw.Draw(bg)
    for y in range(H):
        t = y / max(H - 1, 1)
        draw.line((0, y, W, y), fill=(*lerp_color(top, bottom, t), 255))

    add_glow(bg, (-220, -190), (560, 560), accent, 88)
    add_glow(bg, (900, -220), (560, 560), (154, 197, 255), 72)
    return bg


def place_screenshot(canvas: Image.Image, source: Path, box: tuple[int, int, int, int]) -> None:
    x, y, w, h = box
    shot = Image.open(source).convert("RGB")
    shot = ImageEnhance.Brightness(shot).enhance(1.02)
    shot = ImageEnhance.Contrast(shot).enhance(1.06)
    shot = ImageEnhance.Color(shot).enhance(1.04)
    shot = ImageOps.fit(shot, (w, h), method=Image.Resampling.LANCZOS).convert("RGBA")

    radius = 24
    mask = rounded_mask((w, h), radius)
    rounded = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    rounded.paste(shot, (0, 0), mask=mask)

    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    s_draw = ImageDraw.Draw(shadow)
    s_draw.rounded_rectangle((x + 2, y + 10, x + w + 10, y + h + 14), radius=28, fill=(30, 35, 45, 52))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)))

    frame = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    f_draw = ImageDraw.Draw(frame)
    f_draw.rounded_rectangle((x - 1, y - 1, x + w + 1, y + h + 1), radius=24, outline=(255, 255, 255, 255), width=2)
    canvas.alpha_composite(rounded, (x, y))
    canvas.alpha_composite(frame)


def draw_pills(
    canvas: Image.Image,
    locale: str,
    items: list[str],
    start_x: int,
    start_y: int,
    tint: tuple[int, int, int],
) -> None:
    draw = ImageDraw.Draw(canvas)
    pill_font = load_font(locale, 24)
    x = start_x
    y = start_y
    for item in items:
        label = f"  {item}  "
        bbox = draw.textbbox((0, 0), label, font=pill_font)
        pw = bbox[2] + 26
        ph = 46
        if x + pw > 486:
            x = start_x
            y += ph + 12
        draw.rounded_rectangle((x, y, x + pw, y + ph), radius=20, fill=(*tint, 48), outline=(*tint, 130), width=1)
        draw.text((x + 14, y + 9), item, font=pill_font, fill=(48, 58, 74, 246))
        x += pw + 10


def make_scene(locale: str, scene: dict[str, object], copy: dict[str, object]) -> None:
    canvas = build_background(scene["top"], scene["bottom"], scene["accent"])
    draw = ImageDraw.Draw(canvas)

    panel = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    p_draw = ImageDraw.Draw(panel)
    p_draw.rounded_rectangle((48, 48, 502, 752), radius=28, fill=(255, 255, 255, 188), outline=(255, 255, 255, 210), width=1)
    canvas.alpha_composite(panel)

    title_font = load_font(locale, 54, weight="bold")
    subtitle_font = load_font(locale, 34, weight="bold")
    body_font = load_font(locale, 27)
    tag_font = load_font(locale, 24, weight="bold")
    locale_font = load_font(locale, 21)

    draw.text((80, 84), "NoiseClear for macOS", font=tag_font, fill=(42, 57, 78, 228))
    draw.text((80, 118), copy["locale_label"], font=locale_font, fill=(76, 92, 116, 218))

    title_lines = wrap_text(draw, copy["title"], title_font, max_width=388)
    y = 172
    for line in title_lines[:2]:
        draw.text((80, y), line, font=title_font, fill=(18, 31, 52, 255))
        y += 62

    subtitle_lines = wrap_text(draw, copy["subtitle"], subtitle_font, max_width=388)
    for line in subtitle_lines[:2]:
        draw.text((80, y + 8), line, font=subtitle_font, fill=(44, 65, 94, 245))
        y += 46

    body_lines = wrap_text(draw, copy["desc"], body_font, max_width=388)
    text_y = max(360, y + 26)
    for line in body_lines[:4]:
        draw.text((80, text_y), line, font=body_font, fill=(62, 76, 98, 240))
        text_y += 38

    draw_pills(canvas, locale, copy["pills"], 80, 560, tint=scene["accent"])
    place_screenshot(canvas, INPUT_DIR / scene["screenshot"], (530, 90, 710, 620))

    output_dir = OUTPUT_DIR / locale
    output_dir.mkdir(parents=True, exist_ok=True)
    name = f"mac_appstore_{scene['id']}_{locale}_1280x800.png"
    canvas.convert("RGB").save(output_dir / name, quality=96)


def main() -> None:
    scenes = [
        {
            "id": "01_home",
            "screenshot": "mac_homepage.png",
            "top": (246, 249, 255),
            "bottom": (236, 244, 252),
            "accent": (88, 142, 222),
        },
        {
            "id": "02_play",
            "screenshot": "mac_play.png",
            "top": (244, 251, 255),
            "bottom": (235, 248, 250),
            "accent": (70, 164, 194),
        },
        {
            "id": "03_convert",
            "screenshot": "mac_convert.png",
            "top": (255, 249, 241),
            "bottom": (250, 243, 236),
            "accent": (210, 142, 81),
        },
    ]

    locales: dict[str, dict[str, dict[str, object]]] = {
        "zh-Hans": {
            "01_home": {
                "locale_label": "简体中文",
                "title": "导入即用的人声降噪",
                "subtitle": "音频与视频一站处理",
                "desc": "支持本地文件与在线 URL，快速降低背景噪声，让对话更清晰。",
                "pills": ["音频+视频", "本地文件", "在线 URL", "四语言界面"],
            },
            "02_play": {
                "locale_label": "简体中文",
                "title": "实时播放 即时对比",
                "subtitle": "边听边调，效果更直观",
                "desc": "原声与降噪可随时切换，强度滑杆可调，低延迟预览更顺滑。",
                "pills": ["实时预览", "强度可调", "低延迟", "本地优先处理"],
            },
            "03_convert": {
                "locale_label": "简体中文",
                "title": "批量处理 高效导出",
                "subtitle": "常见格式快速完成",
                "desc": "支持多文件降噪与进度管理，音频视频都能一键导出成品。",
                "pills": ["批量降噪", "波形对比", "MP3/MP4/MOV", "一键导出"],
            },
        },
        "zh-Hant": {
            "01_home": {
                "locale_label": "繁體中文",
                "title": "匯入即用的人聲降噪",
                "subtitle": "音訊與影片一次完成",
                "desc": "支援本機檔案與線上 URL，快速降低背景噪音，讓對話更清楚。",
                "pills": ["音訊+影片", "本機檔案", "線上 URL", "四語介面"],
            },
            "02_play": {
                "locale_label": "繁體中文",
                "title": "即時播放 即刻對比",
                "subtitle": "邊聽邊調整，回饋更直觀",
                "desc": "可隨時切換原聲與降噪，滑桿調整強度，低延遲預覽更流暢。",
                "pills": ["即時預覽", "強度可調", "低延遲", "本機優先處理"],
            },
            "03_convert": {
                "locale_label": "繁體中文",
                "title": "批次處理 快速匯出",
                "subtitle": "常見格式高效完成",
                "desc": "支援多檔降噪與進度管理，音訊與影片都能一鍵匯出成品。",
                "pills": ["批次降噪", "波形對比", "MP3/MP4/MOV", "一鍵匯出"],
            },
        },
        "en": {
            "01_home": {
                "locale_label": "English",
                "title": "Voice Denoise in Seconds",
                "subtitle": "One workflow for audio and video",
                "desc": "Import local files or paste URLs to reduce background noise and improve speech clarity fast.",
                "pills": ["Audio + Video", "Local files", "Online URLs", "4 Languages"],
            },
            "02_play": {
                "locale_label": "English",
                "title": "Real-time Playback Preview",
                "subtitle": "Listen and tune instantly",
                "desc": "Switch between original and denoised audio, then adjust intensity with a smooth low-latency slider.",
                "pills": ["Live preview", "Adjustable intensity", "Low latency", "Local-first"],
            },
            "03_convert": {
                "locale_label": "English",
                "title": "Batch Process, Export Faster",
                "subtitle": "Built for daily production",
                "desc": "Queue multiple files, compare waveforms, and export cleaner results in common media formats.",
                "pills": ["Batch queue", "Waveform compare", "MP3/MP4/MOV", "One-click export"],
            },
        },
        "ja": {
            "01_home": {
                "locale_label": "日本語",
                "title": "すぐ使える人声ノイズ低減",
                "subtitle": "音声も動画もまとめて処理",
                "desc": "ローカルファイルとURL再生に対応。背景ノイズを抑え、会話を聞き取りやすくします。",
                "pills": ["音声+動画", "ローカル対応", "URL再生", "4言語UI"],
            },
            "02_play": {
                "locale_label": "日本語",
                "title": "リアルタイム再生で比較",
                "subtitle": "聞きながら強度を調整",
                "desc": "原音と低減後をすぐ切り替え。スライダーで強度を調整し、低遅延で確認できます。",
                "pills": ["リアルタイム", "強度調整", "低遅延", "ローカル優先"],
            },
            "03_convert": {
                "locale_label": "日本語",
                "title": "まとめて処理して高速書き出し",
                "subtitle": "よく使う形式に対応",
                "desc": "複数ファイルを一括処理。波形を見比べながら、音声・動画をすばやく書き出せます。",
                "pills": ["一括処理", "波形比較", "MP3/MP4/MOV", "ワンクリック"],
            },
        },
    }

    for locale, copy in locales.items():
        for scene in scenes:
            make_scene(locale, scene, copy[scene["id"]])

    total = len(locales) * len(scenes)
    print(f"Generated {total} images in {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
