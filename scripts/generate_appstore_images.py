from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
SRC_DIR = ROOT / "docs" / "snapshots_mac"
OUT_DIR = ROOT / "docs" / "appstore_screenshots"

CANVAS_SIZE = (1280, 800)


CARDS = [
    {
        "input": "mac_homepage.png",
        "output": "mac_appstore_01_overview.png",
        "headline": "一站式音视频人声降噪",
        "subline": "导入即处理，支持常见音频与 MP4/MOV 视频文件",
        "chips": ["RNNoise 实时引擎", "本地处理更私密", "多语言界面"],
    },
    {
        "input": "mac_play.png",
        "output": "mac_appstore_02_streaming.png",
        "headline": "在线流式播放实时降噪",
        "subline": "低延迟边播边降噪，弱网与失败场景自动回退保障可用",
        "chips": ["实时 Tap 降噪", "低延迟播放", "稳定回退策略"],
    },
    {
        "input": "mac_convert.png",
        "output": "mac_appstore_03_export.png",
        "headline": "批量降噪与高质量导出",
        "subline": "支持处理进度与中途停止，音频导出 WAV，视频保持原容器",
        "chips": ["批量任务", "可中止处理", "专业导出"],
    },
]


def load_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = []
    if bold:
        candidates.extend(
            [
                "/System/Library/Fonts/Supplemental/PingFang SC Semibold.ttf",
                "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
            ]
        )
    else:
        candidates.extend(
            [
                "/System/Library/Fonts/Supplemental/PingFang SC Regular.ttf",
                "/System/Library/Fonts/Supplemental/Arial.ttf",
            ]
        )

    for font_path in candidates:
        try:
            return ImageFont.truetype(font_path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size[0], size[1]), radius=radius, fill=255)
    return mask


def fit_image(src: Image.Image, target_size: tuple[int, int]) -> Image.Image:
    sw, sh = src.size
    tw, th = target_size
    scale = min(tw / sw, th / sh)
    nw, nh = int(sw * scale), int(sh * scale)
    resized = src.resize((nw, nh), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", target_size, (0, 0, 0, 0))
    canvas.paste(resized, ((tw - nw) // 2, (th - nh) // 2))
    return canvas


def draw_chip(draw: ImageDraw.ImageDraw, x: int, y: int, text: str, font: ImageFont.ImageFont) -> int:
    l, t, r, b = draw.textbbox((0, 0), text, font=font)
    tw, th = r - l, b - t
    pad_x, pad_y = 16, 10
    w, h = tw + pad_x * 2, th + pad_y * 2
    draw.rounded_rectangle((x, y, x + w, y + h), radius=18, fill=(255, 255, 255, 44), outline=(255, 255, 255, 96), width=1)
    draw.text((x + pad_x, y + pad_y - 1), text, font=font, fill=(245, 248, 255, 255))
    return w


def make_base_gradient(size: tuple[int, int]) -> Image.Image:
    w, h = size
    img = Image.new("RGBA", size, (0, 0, 0, 255))
    px = img.load()
    for y in range(h):
        ry = y / max(h - 1, 1)
        for x in range(w):
            rx = x / max(w - 1, 1)
            r = int(18 + 52 * rx + 20 * ry)
            g = int(32 + 34 * ry + 22 * (1 - rx))
            b = int(78 + 86 * (1 - ry) + 30 * rx)
            px[x, y] = (min(255, r), min(255, g), min(255, b), 255)
    return img


def render_card(conf: dict[str, object]) -> None:
    base = make_base_gradient(CANVAS_SIZE)
    draw = ImageDraw.Draw(base, "RGBA")

    title_font = load_font(64, bold=True)
    body_font = load_font(34, bold=False)
    chip_font = load_font(28, bold=False)
    label_font = load_font(26, bold=True)

    draw.ellipse((780, -90, 1300, 420), fill=(119, 158, 255, 65))
    draw.ellipse((-200, 500, 520, 980), fill=(146, 110, 255, 52))

    draw.rounded_rectangle((72, 72, 298, 132), radius=22, fill=(255, 255, 255, 34), outline=(255, 255, 255, 110), width=1)
    draw.text((96, 88), "VoiceClear", font=label_font, fill=(255, 255, 255, 250))

    draw.text((72, 182), conf["headline"], font=title_font, fill=(255, 255, 255, 255))
    draw.text((72, 278), conf["subline"], font=body_font, fill=(228, 236, 255, 244))

    chip_x = 72
    chip_y = 356
    for chip in conf["chips"]:
        cw = draw_chip(draw, chip_x, chip_y, chip, chip_font)
        chip_x += cw + 14

    card_x, card_y, card_w, card_h = 570, 106, 672, 588

    shadow = Image.new("RGBA", CANVAS_SIZE, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow, "RGBA")
    shadow_draw.rounded_rectangle((card_x + 10, card_y + 14, card_x + card_w + 10, card_y + card_h + 14), radius=36, fill=(0, 0, 0, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(16))
    base.alpha_composite(shadow)

    card = Image.new("RGBA", (card_w, card_h), (255, 255, 255, 230))
    card_draw = ImageDraw.Draw(card, "RGBA")
    card_draw.rounded_rectangle((0, 0, card_w, card_h), radius=32, fill=(255, 255, 255, 230), outline=(255, 255, 255, 246), width=2)

    src = Image.open(SRC_DIR / str(conf["input"])).convert("RGBA")
    preview = fit_image(src, (card_w - 40, card_h - 40))
    mask = rounded_mask((card_w - 40, card_h - 40), 20)
    card.paste(preview, (20, 20), mask)

    card_mask = rounded_mask((card_w, card_h), 32)
    base.paste(card, (card_x, card_y), card_mask)

    out = base.convert("RGB")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out.save(OUT_DIR / str(conf["output"]), format="PNG", optimize=True)


def main() -> None:
    for conf in CARDS:
        render_card(conf)
    print(f"Generated {len(CARDS)} images in {OUT_DIR}")


if __name__ == "__main__":
    main()