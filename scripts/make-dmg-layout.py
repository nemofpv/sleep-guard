#!/usr/bin/env python3
"""Writes Resources/dmg-layout, the .DS_Store that package.sh puts into the disk image.

It is what makes the mounted image open as an installer window: fixed size, icon view, the app
on the left and the Applications shortcut on the right. The names below must match what
package.sh puts into the image. Rerun only when the layout changes:

    python3 -m venv /tmp/dmg-venv && /tmp/dmg-venv/bin/pip install ds_store==1.3.3
    /tmp/dmg-venv/bin/python scripts/make-dmg-layout.py
"""

import os

from ds_store import DSStore

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "dmg-layout")

WINDOW_WIDTH, WINDOW_HEIGHT = 540, 360
ICON_SIZE = 128
ICON_Y = 160
ICONS = {"SleepGuard.app": 140, "Applications": 400}  # horizontal centre of each icon

if os.path.exists(OUT):
    os.remove(OUT)

with DSStore.open(OUT, "w+") as store:
    store["."]["vSrn"] = ("long", 1)
    store["."]["icvl"] = (b"type", b"icnv")  # open in icon view
    store["."]["bwsp"] = {
        "WindowBounds": "{{200, 200}, {%d, %d}}" % (WINDOW_WIDTH, WINDOW_HEIGHT),
        "ShowStatusBar": False,
        "ShowTabView": False,
        "ShowToolbar": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "SidebarWidth": 180,
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 0,  # Finder's default background, so it suits light and dark mode
        "arrangeBy": "none",
        "iconSize": float(ICON_SIZE),
        "textSize": 13.0,
        "labelOnBottom": True,
        "showIconPreview": False,
        "showItemInfo": False,
        "gridSpacing": 100.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }
    for name, x in ICONS.items():
        store[name]["Iloc"] = (x, ICON_Y)

print("Wrote", os.path.normpath(OUT))
