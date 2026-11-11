"""Teste rápido FORA do Nautilus: abre as colunas e o painel de preview numa janela
própria e salva uma captura em PNG. Uso:

    python3 tools/smoke_test.py [pasta] [arquivo-para-preview] [saida.png]
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import gi  # noqa: E402

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Graphene", "1.0")
from gi.repository import Adw, Gio, GLib, Graphene, Gtk  # noqa: E402

from vitrine.columns import ColumnStrip  # noqa: E402
from vitrine.main import CSS  # noqa: E402
from vitrine.preview import PreviewPane  # noqa: E402

folder = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~")
target = sys.argv[2] if len(sys.argv) > 2 else None
out = sys.argv[3] if len(sys.argv) > 3 else "/tmp/vitrine-smoke.png"


def on_activate(app):
    win = Adw.ApplicationWindow(application=app, default_width=1200, default_height=700)
    prov = Gtk.CssProvider()
    prov.load_from_bytes(GLib.Bytes.new(CSS))
    Gtk.StyleContext.add_provider_for_display(win.get_display(), prov, 800)
    events = []
    strip = ColumnStrip(column_width=230, max_visible=3,
                        on_navigate=lambda u: events.append(("nav", u)),
                        on_reveal=lambda f, u: events.append(("reveal", f, u)))
    preview = PreviewPane(on_navigate=print, on_reveal=print, on_quicklook=lambda: None)
    middle = Gtk.Label(label="[lista nativa do Nautilus]", hexpand=True)
    box = Gtk.Box()
    box.append(strip)
    box.append(middle)
    paned = Gtk.Paned(start_child=box, end_child=preview, resize_end_child=False,
                      shrink_end_child=False)
    win.set_content(paned)
    win.present()
    strip.set_location(Gio.File.new_for_path(folder))
    preview.set_folder(Gio.File.new_for_path(folder).get_uri())
    preview.show_uris([Gio.File.new_for_path(target).get_uri()] if target else [])

    def shot():
        paned.set_position(win.get_width() - 330)
        w, h = paned.get_width(), paned.get_height()
        paintable = Gtk.WidgetPaintable.new(paned).get_current_image()
        snap = Gtk.Snapshot()
        paintable.snapshot(snap, w, h)
        node = snap.to_node()
        if node is not None:
            tex = win.get_renderer().render_texture(node, Graphene.Rect().init(0, 0, w, h))
            tex.save_to_png(out)
            print("png:", out)
        rows = []
        c = preview.info.get_first_child()
        while c is not None:
            rows.append(c.get_label())
            c = c.get_next_sibling()
        print("preview:", preview.media.get_visible_child_name(), "|", preview.title.get_text(),
              "|", preview.subtitle.get_text(), "|", rows)
        cols = [(c.folder.get_path(), c.selection.get_model().get_n_items(), c.highlight_uri)
                for c in strip.columns]
        print("colunas:", cols)
        print("eventos:", events)
        app.quit()
        return False

    GLib.timeout_add(2500, shot)


app = Adw.Application(application_id="io.github.vitrine.SmokeTest",
                      flags=Gio.ApplicationFlags.NON_UNIQUE)
app.connect("activate", on_activate)
app.run([])
