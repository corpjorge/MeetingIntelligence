#!/usr/bin/env python3
"""Write Finder layout in our mounted DMG without opening or scripting Finder."""

import sys
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias


def main():
    volume, app_name = Path(sys.argv[1]), sys.argv[2]
    background = volume / ".background" / "background.tiff"
    if not background.is_file() or not (volume / app_name).is_dir():
        raise SystemExit("Faltan la aplicación o el fondo en el volumen de empaquetado.")
    with DSStore.open(str(volume / ".DS_Store"), "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["icvl"] = ("type", b"icnv")
        store["."]["bwsp"] = {
            "WindowBounds": "{{200, 120}, {660, 508}}",
            "ShowToolbar": False,
            "ShowStatusBar": False,
            "ShowPathbar": False,
            "ShowSidebar": False,
            "ContainerShowSidebar": False,
            "PreviewPaneVisibility": False,
            "ShowTabView": False,
            "SidebarWidth": 0,
        }
        store["."]["icvp"] = {
            "viewOptionsVersion": 1,
            "backgroundType": 2,
            "backgroundImageAlias": Alias.for_file(str(background)).to_bytes(),
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "gridSpacing": 100.0,
            "arrangeBy": "none",
            "showIconPreview": False,
            "showItemInfo": False,
            "labelOnBottom": True,
            "textSize": 13.0,
            "iconSize": 104.0,
            "scrollPositionX": 0.0,
            "scrollPositionY": 0.0,
        }
        for name, position in {
            app_name: (170, 150),
            "Aplicaciones": (490, 150),
            "Léeme": (330, 392),
            ".background": (900, 900),
            ".fseventsd": (900, 1000),
            ".VolumeIcon.icns": (1000, 900),
        }.items():
            store[name]["Iloc"] = position


if __name__ == "__main__":
    main()
