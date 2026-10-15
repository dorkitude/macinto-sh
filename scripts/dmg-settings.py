# dmgbuild settings for the Macinto installer window. Used by `make dmg`:
#   uvx dmgbuild -s scripts/dmg-settings.py -D app=... -D background=... -D icon=... "Macinto 0.1.0" out.dmg
# The background is drawn by scripts/make-dmg-background.swift; keep the positions below in sync with it.
# pyright: reportUndefinedVariable=false
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild injects `defines`)
app_name = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines.get("icon")  # noqa: F821  volume icon
background = defines["background"]  # noqa: F821  .tiff with 1x and 2x

window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 14
icon_locations = {
    app_name: (180, 190),
    "Applications": (480, 190),
}
