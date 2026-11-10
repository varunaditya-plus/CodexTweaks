# dmgbuild settings for the release DMG, run from the repo root:
# dmgbuild -s dmg/settings.py -D app="path/to/Codex Tweaks.app" "Codex Tweaks" CodexTweaks.dmg
import os.path

app = defines["app"]
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]

# background@2x.png next to it is picked up automatically for Retina screens.
# Both are exported from Figma frame 69:6 ("random stuff"), scaled to the 640×354 window.
background = "dmg/background.png"
# Finder sizes the whole window, so add the 32 pt macOS 26 title bar to show all 354 pt of the background.
window_rect = ((200, 120), (640, 386))

default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13

# The arrow spans x 272–368 and is centered at y 177.
# Each icon is centered vertically, 60% of the way from its window edge to the arrow.
icon_locations = {
    app_name: (163, 177),
    "Applications": (477, 177),
}
