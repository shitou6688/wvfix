"""生成 App 图标（纯 Python，不依赖 PIL）
用法: python tool/make_icon.py <输出目录>
设计: 微信绿渐变圆角方块 + 白色向上箭头（象征"升版本"）
"""
import os
import struct
import sys
import zlib
import math

OUT = sys.argv[1] if len(sys.argv) > 1 else "WeChatVerFix"

TOP = (0x14, 0xC7, 0x6C)      # 亮绿
BOT = (0x05, 0x9E, 0x4C)      # 深绿
WHITE = (255, 255, 255)


def lerp(a, b, t):
    return int(round(a + (b - a) * t))


def coverage_rounded_rect(x, y, size, radius):
    cx = cy = size / 2.0
    half = size / 2.0
    dx = abs(x - cx) - (half - radius)
    dy = abs(y - cy) - (half - radius)
    dx = max(dx, 0.0)
    dy = max(dy, 0.0)
    d = math.hypot(dx, dy) - radius
    return min(max(0.5 - d, 0.0), 1.0)


def in_triangle(px, py, a, b, c):
    def sign(p1, p2, p3):
        return (p1[0] - p3[0]) * (p2[1] - p3[1]) - (p2[0] - p3[0]) * (p1[1] - p3[1])
    d1 = sign((px, py), a, b)
    d2 = sign((px, py), b, c)
    d3 = sign((px, py), c, a)
    neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    pos = (d1 > 0) or (d2 > 0) or (d3 > 0)
    return not (neg and pos)


def in_rect(px, py, x0, y0, x1, y1):
    return x0 <= px <= x1 and y0 <= py <= y1


def arrow_coverage(px, py, size):
    """归一化坐标下的上传箭头：三角箭头 + 竖杆"""
    u = (px / size - 0.5) * 2.0      # -1..1
    v = (py / size - 0.5) * 2.0      # -1..1（y 向下）

    # 竖杆
    if in_rect(u, v, -0.15, -0.62, 0.15, 0.10):
        return 1.0
    # 三角箭头（朝上）
    if in_triangle(u, v, (0.0, -0.88), (-0.46, -0.28), (0.46, -0.28)):
        return 1.0
    return 0.0


def render(size):
    radius = size * 0.225
    ss = 4  # 4x 超采样做抗锯齿
    rows = []
    for y in range(size):
        row = []
        for x in range(size):
            r_acc = g_acc = b_acc = a_acc = 0.0
            for sy in range(ss):
                for sx in range(ss):
                    px = x + (sx + 0.5) / ss
                    py = y + (sy + 0.5) / ss
                    cov = coverage_rounded_rect(px, py, size, radius)
                    if cov <= 0.0:
                        continue
                    t = py / size
                    r = lerp(TOP[0], BOT[0], t)
                    g = lerp(TOP[1], BOT[1], t)
                    b = lerp(TOP[2], BOT[2], t)
                    acov = arrow_coverage(px, py, size)
                    if acov > 0:
                        r = lerp(r, WHITE[0], acov)
                        g = lerp(g, WHITE[1], acov)
                        b = lerp(b, WHITE[2], acov)
                    r_acc += r * cov
                    g_acc += g * cov
                    b_acc += b * cov
                    a_acc += cov
            n = ss * ss
            a = a_acc / n
            if a <= 0.0001:
                row.append((0, 0, 0, 0))
            else:
                row.append((int(r_acc / a_acc), int(g_acc / a_acc), int(b_acc / a_acc), int(a * 255)))
        rows.append(row)
    return rows


def write_png(path, rows):
    h = len(rows)
    w = len(rows[0])
    raw = bytearray()
    for row in rows:
        raw.append(0)
        for px in row:
            raw.extend(px)

    def chunk(tag, data):
        out = struct.pack(">I", len(data)) + tag + data
        out += struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        return out

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", ihdr)
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")

    with open(path, "wb") as f:
        f.write(png)


def main():
    os.makedirs(OUT, exist_ok=True)
    sizes = {
        "AppIcon60x60@2x.png": 120,
        "AppIcon60x60@3x.png": 180,
        "AppIcon29x29@2x.png": 58,
        "AppIcon29x29@3x.png": 87,
        "AppIcon76x76@2x.png": 152,
    }
    for name, size in sizes.items():
        rows = render(size)
        path = os.path.join(OUT, name)
        write_png(path, rows)
        print("生成", path, size, "x", size, os.path.getsize(path), "bytes")


if __name__ == "__main__":
    main()
