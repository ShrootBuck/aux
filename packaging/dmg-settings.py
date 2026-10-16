"""Finder layout written directly by dmgbuild; no Finder automation required."""
from pathlib import Path

app = Path(defines["app"]).resolve()
files = [str(app), (defines["readme"], "Install.txt")]
symlinks = {"Applications": "/Applications"}
icon = str(app / "Contents/Resources/Aux.icns")
format = "UDZO"
filesystem = "HFS+"
background = "builtin-arrow"
window_rect = ((200, 150), (640, 420))
icon_locations = {"Aux.app": (180, 170), "Applications": (460, 170), "Install.txt": (320, 320)}
icon_size = 100
text_size = 14
default_view = "icon-view"
include_icon_view_settings = True
include_list_view_settings = False
show_status_bar = False
show_toolbar = False
show_sidebar = False
# Hiding an extension writes FinderInfo onto the signed app bundle, which fails
# strict code-signature validation. Leave its metadata untouched in the image.
