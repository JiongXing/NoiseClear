#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parents[1]
INPUT_DIR = ROOT / "appstore" / "screenshots" / "ios"
OUTPUT_DIR = ROOT / "appstore" / "appstore_assets" / "ios"

W, H = 1242, 2688


def load_font(locale: str, size: int, weight: str = "regular") -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    cjk_regular = [
        Path("/System/Library/Fonts/Hiragino Sans GB.ttc"),
        Path("/System/Library/Fonts/STHeiti Light.ttc"),
        Path("/Library/Fonts/Arial Unicode.ttf"),
    ]
    cjk_bold = [
        Path("/System/Library/Fonts/STHeiti Medium.ttc"),
        Path("/System/Library/Fonts/Hiragino Sans GB.ttc"),
        Path("/Library/Fonts/Arial Unicode.ttf"),
    ]
    en_regular = [
        Path("/System/Library/Fonts/SFNS.ttf"),
        Path("/System/Library/Fonts/HelveticaNeue.ttc"),
        Path("/System/Library/Fonts/Helvetica.ttc"),
        Path("/Library/Fonts/Arial.ttf"),
    ]
    en_bold = [
        Path("/System/Library/Fonts/SFNS.ttf"),
        Path("/System/Library/Fonts/HelveticaNeue.ttc"),
        Path("/Library/Fonts/Arial Bold.ttf"),
    ]

    use_cjk = locale in {"zh-Hans", "zh-Hant", "ja"}
    if use_cjk:
        candidates = cjk_bold if weight != "regular" else cjk_regular
    else:
        candidates = en_bold if weight != "regular" else en_regular

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
        words = text.split()
        lines: list[str] = []
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


def build_background(accent: tuple[int, int, int]) -> Image.Image:
    canvas = Image.new("RGBA", (W, H), (255, 255, 255, 255))
    draw = ImageDraw.Draw(canvas)
    for y in range(H):
        t = y / max(H - 1, 1)
        draw.line((0, y, W, y), fill=(*lerp_color((246, 250, 255), (240, 248, 255), t), 255))

    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(glow)
    gdraw.ellipse((-250, -180, 520, 520), fill=(*accent, 52))
    gdraw.ellipse((760, 1550, 1460, 2280), fill=(116, 188, 226, 34))
    gdraw.ellipse((-220, 1940, 500, 2660), fill=(141, 171, 255, 26))
    canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(64)))
    return canvas


def place_screenshot(canvas: Image.Image, source: Path, box: tuple[int, int, int, int]) -> None:
    x, y, w, h = box
    shot = Image.open(source).convert("RGB")
    shot = ImageEnhance.Brightness(shot).enhance(1.02)
    shot = ImageEnhance.Contrast(shot).enhance(1.06)
    shot = ImageEnhance.Color(shot).enhance(1.03)
    shot = ImageOps.fit(shot, (w, h), method=Image.Resampling.LANCZOS).convert("RGBA")

    radius = 30
    shot_mask = rounded_mask((w, h), radius)
    rounded = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    rounded.paste(shot, (0, 0), mask=shot_mask)

    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow)
    sdraw.rounded_rectangle((x + 6, y + 10, x + w + 12, y + h + 16), radius=32, fill=(20, 28, 41, 56))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))

    frame = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    fdraw = ImageDraw.Draw(frame)
    fdraw.rounded_rectangle((x - 1, y - 1, x + w + 1, y + h + 1), radius=30, outline=(255, 255, 255, 248), width=2)

    canvas.alpha_composite(rounded, (x, y))
    canvas.alpha_composite(frame)


def draw_chip(
    draw: ImageDraw.ImageDraw,
    x: int,
    y: int,
    text: str,
    font: ImageFont.ImageFont,
    tint: tuple[int, int, int],
) -> int:
    l, t, r, b = draw.textbbox((0, 0), text, font=font)
    tw, th = r - l, b - t
    pad_x, pad_y = 18, 12
    w, h = tw + pad_x * 2, th + pad_y * 2
    draw.rounded_rectangle((x, y, x + w, y + h), radius=22, fill=(*tint, 44), outline=(*tint, 116), width=1)
    draw.text((x + pad_x, y + pad_y - 1), text, font=font, fill=(48, 67, 96, 248))
    return w


def render(locale: str, scene: dict[str, object]) -> None:
    accent = tuple(scene["accent"])
    canvas = build_background(accent=accent)
    draw = ImageDraw.Draw(canvas)

    tag_font = load_font(locale, 38, weight="bold")
    title_font = load_font(locale, 94, weight="bold")
    subtitle_font = load_font(locale, 46, weight="regular")
    chip_font = load_font(locale, 32)
    footer_font = load_font(locale, 34, weight="bold")

    draw.rounded_rectangle((78, 74, 394, 164), radius=30, fill=(255, 255, 255, 210), outline=(255, 255, 255, 255), width=1)
    draw.text((112, 100), "NoiseClear", font=tag_font, fill=(34, 63, 98, 245))

    title_lines = wrap_text(draw, str(scene["title"]), title_font, max_width=1088)
    y = 230
    for line in title_lines[:2]:
        draw.text((82, y), line, font=title_font, fill=(18, 44, 76, 255))
        y += 112

    subtitle_lines = wrap_text(draw, str(scene["subtitle"]), subtitle_font, max_width=1088)
    for line in subtitle_lines[:2]:
        draw.text((84, y + 6), line, font=subtitle_font, fill=(55, 82, 120, 238))
        y += 63

    screenshot_w = 780
    screenshot_h = 1560
    row_x = (W - screenshot_w) // 2
    row_y = 700
    place_screenshot(canvas, INPUT_DIR / str(scene["screenshot"]), (row_x, row_y, screenshot_w, screenshot_h))

    chip_y = row_y + screenshot_h + 56
    chip_x = 84
    tint = accent
    for chip in scene["chips"]:
        cw = draw_chip(draw, chip_x, chip_y, str(chip), chip_font, tint=tint)
        chip_x += cw + 16

    draw.text((84, H - 168), str(scene["footer"]), font=footer_font, fill=(52, 76, 111, 238))

    locale_output_dir = OUTPUT_DIR / locale
    locale_output_dir.mkdir(parents=True, exist_ok=True)
    output_name = f"ios_appstore_poster_{scene['id']}_1242x2688.png"
    canvas.convert("RGB").save(locale_output_dir / output_name, format="PNG", optimize=True)


def main() -> None:
    copies: dict[str, dict[str, dict[str, object]]] = {
        "zh-Hans": {
            "scenes": {
                "01_home": {
                    "id": "01_home",
                    "screenshot": "ios_homepage.png",
                    "accent": (94, 151, 224),
                    "title": "导入即用的人声降噪",
                    "subtitle": "本地文件与在线链接都能快速处理",
                    "chips": ["音频+视频", "本地文件", "在线 URL"],
                    "footer": "降低背景噪声，让每一句话更容易听清。",
                },
                "02_play": {
                    "id": "02_play",
                    "screenshot": "ios_play.png",
                    "accent": (76, 171, 198),
                    "title": "实时播放 即时对比",
                    "subtitle": "边听边调，降噪效果更直观",
                    "chips": ["实时预览", "强度可调", "低延迟"],
                    "footer": "原声与降噪随时切换，快速找到理想听感。",
                },
                "03_convert": {
                    "id": "03_convert",
                    "screenshot": "ios_convert.png",
                    "accent": (208, 145, 92),
                    "title": "批量处理 高效导出",
                    "subtitle": "常见音视频格式一键生成成品",
                    "chips": ["批量降噪", "进度可见", "一键导出"],
                    "footer": "减少后期时间，让音视频处理更轻松。",
                },
            },
        },
        "zh-Hant": {
            "scenes": {
                "01_home": {
                    "id": "01_home",
                    "screenshot": "ios_homepage.png",
                    "accent": (94, 151, 224),
                    "title": "匯入即用的人聲降噪",
                    "subtitle": "本機檔案與線上連結都能快速處理",
                    "chips": ["音訊+影片", "本機檔案", "線上 URL"],
                    "footer": "降低背景噪音，讓每一句話都更容易聽清楚。",
                },
                "02_play": {
                    "id": "02_play",
                    "screenshot": "ios_play.png",
                    "accent": (76, 171, 198),
                    "title": "即時播放 即刻對比",
                    "subtitle": "邊聽邊調整，降噪回饋更直觀",
                    "chips": ["即時預覽", "強度可調", "低延遲"],
                    "footer": "原聲與降噪可隨時切換，快速找到理想聽感。",
                },
                "03_convert": {
                    "id": "03_convert",
                    "screenshot": "ios_convert.png",
                    "accent": (208, 145, 92),
                    "title": "批次處理 快速匯出",
                    "subtitle": "常見音影片格式一鍵完成",
                    "chips": ["批次降噪", "進度可見", "一鍵匯出"],
                    "footer": "減少後製時間，讓音影片處理更輕鬆。",
                },
            },
        },
        "en": {
            "scenes": {
                "01_home": {
                    "id": "01_home",
                    "screenshot": "ios_homepage.png",
                    "accent": (94, 151, 224),
                    "title": "Voice Denoise in Seconds",
                    "subtitle": "Process local files and online URLs in one flow",
                    "chips": ["Audio + Video", "Local files", "Online URLs"],
                    "footer": "Reduce background noise and make speech easier to follow.",
                },
                "02_play": {
                    "id": "02_play",
                    "screenshot": "ios_play.png",
                    "accent": (76, 171, 198),
                    "title": "Real-time Playback Preview",
                    "subtitle": "Listen and tune denoise intensity instantly",
                    "chips": ["Live preview", "Adjustable intensity", "Low latency"],
                    "footer": "Switch between original and denoised sound with one tap.",
                },
                "03_convert": {
                    "id": "03_convert",
                    "screenshot": "ios_convert.png",
                    "accent": (208, 145, 92),
                    "title": "Batch Process, Export Faster",
                    "subtitle": "Handle common audio and video formats quickly",
                    "chips": ["Batch queue", "Visible progress", "One-tap export"],
                    "footer": "Save editing time and deliver cleaner voice content faster.",
                },
            },
        },
        "ja": {
            "scenes": {
                "01_home": {
                    "id": "01_home",
                    "screenshot": "ios_homepage.png",
                    "accent": (94, 151, 224),
                    "title": "すぐ使える人声ノイズ低減",
                    "subtitle": "ローカルファイルとURL再生に対応",
                    "chips": ["音声+動画", "ローカル対応", "URL再生"],
                    "footer": "背景ノイズを抑えて、会話をより聞き取りやすく。",
                },
                "02_play": {
                    "id": "02_play",
                    "screenshot": "ios_play.png",
                    "accent": (76, 171, 198),
                    "title": "リアルタイム再生で比較",
                    "subtitle": "聞きながら強度を調整してすぐ確認",
                    "chips": ["リアルタイム", "強度調整", "低遅延"],
                    "footer": "原音と低減後をワンタップで切り替えできます。",
                },
                "03_convert": {
                    "id": "03_convert",
                    "screenshot": "ios_convert.png",
                    "accent": (208, 145, 92),
                    "title": "まとめて処理して高速書き出し",
                    "subtitle": "よく使う音声・動画形式に対応",
                    "chips": ["一括処理", "進捗表示", "ワンクリック"],
                    "footer": "後処理の手間を減らし、作業を効率化します。",
                },
            },
        },
    }

    total = 0
    for locale, locale_copy in copies.items():
        for scene in locale_copy["scenes"].values():
            render(locale, scene)
            total += 1
    print(f"Generated {total} iOS posters in {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
