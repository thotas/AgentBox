#!/usr/bin/env python3
"""
Generate high-resolution macOS app icon for AgentBox.
Creates Apple-style app icons with rounded corners and gradient backgrounds.
"""

import os
import math
from PIL import Image, ImageDraw, ImageFont

# Icon sizes needed for macOS (in pixels)
SIZES = [
    (16, 1),
    (16, 2),
    (32, 1),
    (32, 2),
    (128, 1),
    (128, 2),
    (256, 1),
    (256, 2),
    (512, 1),
    (512, 2),
]

def create_rounded_rectangle(width, height, radius, fill, draw):
    """Draw a rounded rectangle."""
    draw.rounded_rectangle(
        [(0, 0), (width - 1, height - 1)],
        radius=radius,
        fill=fill
    )

def create_icon(size, scale):
    """Create a single icon at the given size and scale - Apple News style."""
    actual_size = size * scale
    radius = int(actual_size * 0.2237)  # Apple's standard corner radius ratio

    # Create image with RGBA
    img = Image.new('RGBA', (actual_size, actual_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Create a beautiful gradient background - Apple News inspired
    # Vibrant blue to purple/pink gradient
    center_x = actual_size // 2
    center_y = actual_size // 2
    max_radius = actual_size * 0.7

    # Draw radial gradient - from bright center to darker edges
    for i in range(40, 0, -1):
        ratio = i / 40.0
        # Rich blue (#007AFF) to purple (#5856D6) to pink (#FF2D55)
        if ratio > 0.6:
            # Blue to purple
            local_ratio = (1 - ratio) / 0.4
            r = int(0 + (88 - 0) * local_ratio)
            g = int(122 + (86 - 122) * local_ratio)
            b = int(255 + (214 - 255) * local_ratio)
        else:
            # Purple to pink
            local_ratio = (0.6 - ratio) / 0.6
            r = int(88 + (255 - 88) * local_ratio)
            g = int(86 + (45 - 86) * local_ratio)
            b = int(214 + (85 - 214) * local_ratio)

        layer_size = int(actual_size * (0.3 + 0.7 * ratio))
        offset = (actual_size - layer_size) // 2

        draw.rounded_rectangle(
            [offset, offset, offset + layer_size - 1, offset + layer_size - 1],
            radius=int(radius * (0.3 + 0.7 * ratio)),
            fill=(r, g, b, 255)
        )

    # Add subtle inner glow/vignette effect
    for i in range(15, 0, -1):
        ratio = i / 15.0
        r = int(255 * (1 - ratio) * 0.15)
        g = int(255 * (1 - ratio) * 0.15)
        b = int(255 * (1 - ratio) * 0.15)
        inner_radius = int(max_radius * ratio)
        draw.ellipse(
            [center_x - inner_radius, center_y - inner_radius,
             center_x + inner_radius, center_y + inner_radius],
            outline=(r, g, b, 40)
        )

    # Apple-style shine at top
    shine_height = int(actual_size * 0.25)
    for i in range(shine_height):
        alpha = int(40 * (1 - i / shine_height))
        y = int(actual_size * 0.05) + i
        width_top = int(actual_size * 0.8 * (1 - i / shine_height * 0.3))
        width_bottom = int(actual_size * 0.8 * (1 - i / shine_height * 0.1))
        x_left = (actual_size - width_top) // 2
        x_right = x_left + width_top
        draw.line(
            [(x_left, y), (x_right, y)],
            fill=(255, 255, 255, alpha),
            width=1
        )

    # Draw stylized "AB" letters with modern typography
    # Using simple geometric shapes to create letters
    letter_color = (255, 255, 255, 240)

    # Letter "A" - modern geometric style
    a_margin = int(actual_size * 0.2)
    a_height = int(actual_size * 0.45)
    a_width = int(actual_size * 0.25)

    # A main shape
    a_points = [
        (a_margin, a_margin + a_height),  # Bottom left
        (a_margin + a_width // 2, a_margin),  # Top center
        (a_margin + a_width, a_margin + a_height),  # Bottom right
    ]
    # Draw A as thick lines
    line_width = max(2, int(actual_size * 0.06))

    # A left leg
    draw.line([a_points[0], a_points[1]], fill=letter_color, width=line_width)
    # A right leg
    draw.line([a_points[1], a_points[2]], fill=letter_color, width=line_width)
    # A crossbar
    crossbar_y = a_margin + int(a_height * 0.6)
    draw.line([
        (a_margin + int(a_width * 0.25), crossbar_y),
        (a_margin + int(a_width * 0.75), crossbar_y)
    ], fill=letter_color, width=max(1, line_width // 2))

    # Letter "B" - next to A
    b_margin = a_margin + a_width + int(actual_size * 0.08)
    b_height = a_height
    b_width = int(actual_size * 0.22)

    # B vertical line
    draw.line([
        (b_margin, a_margin),
        (b_margin, a_margin + b_height)
    ], fill=letter_color, width=line_width)

    # B top curve (simplified as lines)
    curve_points = 8
    for i in range(curve_points):
        t = i / (curve_points - 1)
        x = b_margin + int(b_width * math.sin(t * math.pi / 2))
        y1 = a_margin + int(b_height * 0.15 * t)
        y2 = a_margin + int(b_height * (0.15 + 0.35 * t))
        draw.line([(x, y1), (x, y2)], fill=letter_color, width=line_width)

    # B bottom curve
    for i in range(curve_points):
        t = i / (curve_points - 1)
        x = b_margin + int(b_width * math.sin(t * math.pi / 2))
        y1 = a_margin + int(b_height * (0.5 + 0.35 * t))
        y2 = a_margin + int(b_height * (0.85 + 0.15 * t))
        draw.line([(x, y1), (x, y2)], fill=letter_color, width=line_width)

    # Add subtle shadow/depth under letters
    shadow_offset = int(actual_size * 0.02)
    shadow_color = (0, 0, 0, 30)
    # Simple shadow effect by drawing slightly offset
    draw_line_shifted = lambda p1, p2: draw.line([
        (p1[0] + shadow_offset, p1[1] + shadow_offset),
        (p2[0] + shadow_offset, p2[1] + shadow_offset)
    ], fill=shadow_color, width=line_width)

    # Add final outer glow for premium feel
    glow_layers = 3
    for i in range(glow_layers):
        alpha = int(20 / (i + 1))
        glow_radius = radius + int(actual_size * 0.02 * (i + 1))
        draw.rounded_rectangle(
            [0, 0, actual_size - 1, actual_size - 1],
            radius=glow_radius,
            outline=(255, 255, 255, alpha),
            width=1
        )

    return img

def main():
    # Get the directory where this script is located
    script_dir = os.path.dirname(os.path.abspath(__file__))
    output_dir = os.path.join(script_dir, "Sources", "AgentBox", "Resources", "Assets.xcassets", "AppIcon.appiconset")

    # Create output directory if it doesn't exist
    os.makedirs(output_dir, exist_ok=True)

    print(f"Generating icons in {output_dir}")

    # Generate all required sizes
    for size, scale in SIZES:
        img = create_icon(size, scale)

        if scale == 1:
            filename = f"icon_{size}x{size}.png"
        else:
            filename = f"icon_{size}x{size}@{scale}x.png"

        filepath = os.path.join(output_dir, filename)
        img.save(filepath, "PNG")
        print(f"  Created {filename}")

    # Update Contents.json with proper configuration
    contents_json = '''{
  "images" : [
    {
      "filename" : "icon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}'''

    with open(os.path.join(output_dir, "Contents.json"), 'w') as f:
        f.write(contents_json)

    print("Done! Icon set generated successfully.")

if __name__ == "__main__":
    main()
