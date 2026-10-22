# dmgbuild settings for Bubbleg.dmg: the app on the left, an Applications shortcut on the right,
# and the arrow between them on the background. Paths come in through -D app=... background=... icon=...
# (dmg/make.sh passes them). The icon positions match where background.tiff draws the arrow.
import os

app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]

format = "UDZO"
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    os.path.basename(app): (170, 180),
    "Applications": (470, 180),
}
