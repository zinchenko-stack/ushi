# Окно установщика ushi.dmg для dmgbuild: Ushi слева, стрелка, «Программы» справа,
# подсказка снизу (фон — scripts/make-dmg-background.swift, координаты совпадают).
# Вызывается из scripts/build-ushinext-dmg.sh.
import os.path

application = defines['app']
appname = os.path.basename(application)

# Скрипт сборки просит UDRW: после dmgbuild из .DS_Store убирается запись pBBk
# (см. build-ushinext-dmg.sh), потом образ сжимается в UDZO.
format = defines.get('format', 'UDZO')
files = [application]
symlinks = {'Программы': '/Applications'}
icon = os.path.join(application, 'Contents', 'Resources', 'AppIcon.icns')
background = defines['background']

window_rect = ((200, 160), (640, 400))
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False

arrange_by = None
label_pos = 'bottom'
text_size = 13
icon_size = 128
icon_locations = {
    appname: (170, 175),
    'Программы': (470, 175),
}
