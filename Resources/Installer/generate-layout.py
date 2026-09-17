"""Regenerate FinderLayout with: python3 -m pip install ds-store==1.3.3

Only asset maintainers need ds-store. Packaging copies the resulting metadata
without invoking Finder or changing the user's Finder preferences.
"""

from pathlib import Path

from ds_store import DSStore

with DSStore.open(str(Path(__file__).with_name("FinderLayout")), "w+") as store:
    store["."]["vSrn"] = ("long", 1)
    store["."]["icvl"] = ("type", b"icnv")
    store["."]["bwsp"] = {
        "ShowStatusBar": False,
        "ShowToolbar": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
        "ShowTabView": False,
        "ContainerShowSidebar": False,
        "WindowBounds": "{{200, 160}, {660, 480}}",
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 1,
        "backgroundColorRed": 0.98,
        "backgroundColorGreen": 0.98,
        "backgroundColorBlue": 0.99,
        "arrangeBy": "none",
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "iconSize": 112.0,
        "textSize": 14.0,
        "labelOnBottom": True,
        "showItemInfo": False,
        "showIconPreview": False,
    }
    store["Speaker.app"]["Iloc"] = (165, 145)
    store["Applications"]["Iloc"] = (495, 145)
    store["拖动 Speaker 到 Applications 安装.txt"]["Iloc"] = (330, 320)
