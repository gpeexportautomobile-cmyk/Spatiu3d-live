#!/usr/bin/env python3
import plistlib, os, sys
from pathlib import Path

app, name, bundle, display = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
version = sys.argv[5] if len(sys.argv) > 5 else "1.0"
info = {
  "CFBundleExecutable": name,
  "CFBundleIdentifier": bundle,
  "CFBundleName": display,
  "CFBundleDisplayName": display,
  "CFBundlePackageType": "APPL",
  "CFBundleShortVersionString": version,
  "CFBundleVersion": "1",
  "CFBundleInfoDictionaryVersion": "6.0",
  "CFBundleDevelopmentRegion": "ro",
  "MinimumOSVersion": "14.0",
  "CFBundleSupportedPlatforms": ["iPhoneOS"],
  "NSMotionUsageDescription": "Aplicația folosește senzorii de mișcare.",
  "UIDeviceFamily": [1],
  "UIRequiredDeviceCapabilities": ["arm64"],
  "LSRequiresIPhoneOS": True,
  "UILaunchScreen": {},
  "UISupportedInterfaceOrientations": [
      "UIInterfaceOrientationPortrait",
      "UIInterfaceOrientationLandscapeLeft",
      "UIInterfaceOrientationLandscapeRight",
  ],
  "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
  "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon60x60"]}},
  "DTPlatformName": "iphoneos",
  "DTSDKName": "iphoneos16.5",
  "DTPlatformVersion": "16.5",
}
Path(app, "Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
Path(app, "PkgInfo").write_text("APPL????")

# Optional Pillow icon; fallback to a solid PPM-less raw write via a tiny PNG if Pillow missing.
def solid_png(path, size, rgb, letter):
    try:
        from PIL import Image, ImageDraw, ImageFont
        im = Image.new("RGB", (size, size), rgb)
        d = ImageDraw.Draw(im)
        # light letter in the center
        try:
            font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", size=int(size*0.5))
        except Exception:
            font = ImageFont.load_default()
        ch = (letter or name[:1] or "A")[:1].upper()
        bbox = d.textbbox((0, 0), ch, font=font)
        tw, th = bbox[2]-bbox[0], bbox[3]-bbox[1]
        d.text(((size-tw)/2 - bbox[0], (size-th)/2 - bbox[1]), ch, fill=(255, 255, 255), font=font)
        im.save(path)
        return
    except Exception:
        pass
    # 1x1 pixel PNG fallback is invalid as icon but keeps packaging working.
    import struct, zlib
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag+data) & 0xffffffff)
    raw = b"".join(b"\x00" + bytes([rgb[0], rgb[1], rgb[2]])*size for _ in range(size))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    Path(path).write_bytes(png)

letter = display[:1] if display else name[:1]
rgb = (30, 90, 200)
try:
    import json
    t = json.load(open("assets/spec.json")).get("theme", {}).get("tint", "")
    if isinstance(t, str) and t.startswith("#") and len(t) >= 7:
        rgb = tuple(int(t[i:i+2], 16) for i in (1, 3, 5))
except Exception:
    pass
solid_png(os.path.join(app, "AppIcon60x60@2x.png"), 120, rgb, letter)
solid_png(os.path.join(app, "AppIcon60x60@3x.png"), 180, rgb, letter)
