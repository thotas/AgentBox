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
    """Create a single icon at the given size and scale."""
    actual_size = size * scale
    radius = int(actual_size * 0.2237)  # Apple's standard corner radius ratio

    # Create image with RGBA
    img = Image.new('RGBA', (actual_size, actual_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Create gradient background - deep blue to purple (AgentBox brand)
    # Using a more subtle, professional gradient like Apple News app
    center_x = actual_size // 2
    center_y = actual_size // 2

    # Draw gradient layers
    for i in range(20, 0, -1):
        ratio = i / 20.0
        # Deep blue (#1a1a2e) to purple (#4a0e4e)
        r = int(26 + (74 - 26) * ratio)
        g = int(26 + (14 - 26) * ratio)
        b = int(46 + (78 - 46) * ratio)
        layer_size = int(actual_size * (0.85 + 0.15 * ratio))
        offset = (actual_size - layer_size) // 2

        draw.rounded_rectangle(
            [offset, offset, offset + layer_size - 1, offset + layer_size - 1],
            radius=int(radius * (0.85 + 0.15 * ratio)),
            fill=(r, g, b, 255)
        )

    # Add subtle shine at top (Apple-style)
    shine_height = int(actual_size * 0.15)
    shine_rect = [
        int(actual_size * 0.1),
        int(actual_size * 0.08),
        int(actual_size * 0.9),
        int(actual_size * 0.08) + shine_height
    ]

    # Draw a subtle highlight
    for i in range(shine_height):
        alpha = int(30 * (1 - i / shine_height))
        y = shine_rect[1] + i
        draw.line(
            [(shine_rect[0], y), (shine_rect[2], y)],
            fill=(255, 255, 255, alpha),
            width=1
        )

    # Draw stylized "AB" monogram or box icon
    # Let's create a modern box with connections (agent orchestration)
    box_margin = int(actual_size * 0.22)
    box_size = int(actual_size * 0.56)
    inner_margin = box_margin + int(box_size * 0.15)
    inner_box_size = box_size - int(box_size * 0.3)

    # Outer box (connection points)
    draw.rounded_rectangle(
        [box_margin, box_margin, box_margin + box_size, box_margin + box_size],
        radius=int(radius * 0.6),
        outline=(255, 255, 255, 200),
        width=max(1, int(actual_size * 0.02))
    )

    # Inner nodes (representing agents)
    node_size = int(actual_size * 0.12)
    node_positions = [
        (inner_margin, inner_margin),  # Top-left
        (inner_margin + inner_box_size - node_size, inner_margin),  # Top-right
        (inner_margin, inner_margin + inner_box_size - node_size),  # Bottom-left
        (inner_margin + inner_box_size - node_size, inner_margin + inner_box_size - node_size),  # Bottom-right
        (center_x - node_size // 2, center_y - node_size // 2),  # Center
    ]

    # Draw connecting lines
    line_color = (255, 255, 255, 120)
    line_width = max(1, int(actual_size * 0.015))

    # Connect outer nodes to center
    for pos in node_positions[:4]:
        center_pos = (node_positions[4][0] + node_size // 2, node_positions[4][1] + node_size // 2)
        node_center = (pos[0] + node_size // 2, pos[1] + node_size // 2)
        draw.line([node_center, center_pos], fill=line_color, width=line_width)

    # Draw outer nodes (agents)
    for pos in node_positions[:4]:
        draw.rounded_rectangle(
            [pos[0], pos[1], pos[0] + node_size, pos[1] + node_size],
            radius=int(node_size * 0.25),
            fill=(100, 180, 255, 230)
        )

    # Draw center node (coordinator/manager)
    center_pos = node_positions[4]
    draw.rounded_rectangle(
        [center_pos[0], center_pos[1], center_pos[0] + node_size, center_pos[1] + node_size],
        radius=int(node_size * 0.25),
        fill=(255, 200, 100, 230)
    )

    # Add glow effect around center node
    glow_radius = int(node_size * 0.8)
    for i in range(10, 0, -1):
        alpha = int(15 * (1 - i / 10))
        r = int(node_size // 2 + glow_radius * i / 10)
        cx, cy = center_pos[0] + node_size // 2, center_pos[1] + node_size // 2
        draw.ellipse(
            [cx - r, cy - r, cx + r, cy + r],
            outline=(255, 200, 100, alpha)
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
