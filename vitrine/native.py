"""Ponte com as partes internas do Nautilus (aba/slot, modo de visualização, seleção).

Regra de ouro: nunca guardar referência forte a widgets ou modelos do Nautilus.
Tudo é procurado sob demanda; o modelo de seleção é acompanhado por weak_ref.
"""

from __future__ import annotations

from gi.repository import Adw, Gio, GLib, Gtk

from .util import debug, find_first, gtype_name, log, walk

# Locais onde o Nautilus fixa a própria visualização (não aplicamos regras).
SPECIAL_SCHEMES = ("recent", "starred", "trash", "x-network-view", "network", "computer",
                   "search", "other-locations", "burn", "admin-root")


def is_nautilus_window(win) -> bool:
    return gtype_name(win) == "NautilusWindow"


def find_tab_view(win) -> Adw.TabView | None:
    return find_first(win, lambda w: isinstance(w, Adw.TabView))


def active_slot(win):
    tv = find_tab_view(win)
    if tv is None:
        return None
    page = tv.get_selected_page()
    return page.get_child() if page is not None else None


def slot_location(slot) -> Gio.File | None:
    if slot is None:
        return None
    try:
        return slot.get_property("location")
    except TypeError:
        return None


def slot_uri(slot) -> str | None:
    loc = slot_location(slot)
    return loc.get_uri() if loc is not None else None


def is_regular_location(uri: str | None) -> bool:
    if not uri:
        return False
    scheme = GLib.Uri.peek_scheme(uri) or ""
    return scheme not in SPECIAL_SCHEMES


def open_location(slot, uri: str) -> bool:
    if slot is None:
        return False
    return bool(slot.activate_action("slot.open-location", GLib.Variant("s", uri)))


# ── barra lateral nativa ──

def _prop(obj, name):
    try:
        return obj.get_property(name)
    except (TypeError, AttributeError):
        return None


def sidebar_places(win) -> list[dict]:
    """Os locais da barra lateral do Nautilus, na mesma ordem e com os mesmos nomes.

    Lê as propriedades de cada NautilusSidebarRow (uri, label, start-icon…).
    Linhas de dispositivos (com mount/volume/drive) vêm marcadas em `device`."""
    sidebar = find_first(win, lambda w: gtype_name(w) == "NautilusSidebar")
    if sidebar is None:
        return []
    out = []
    for row in walk(sidebar):
        if gtype_name(row) != "NautilusSidebarRow":
            continue
        uri = _prop(row, "uri")
        label = _prop(row, "label")
        if not uri or not label or _prop(row, "placeholder"):
            continue
        if row.has_css_class("sidebar-new-bookmark-row"):
            continue
        device = any(_prop(row, p) is not None for p in ("mount", "volume", "drive"))
        out.append({
            "uri": uri,
            "label": label,
            "gicon": _prop(row, "start-icon"),
            "section": int(_prop(row, "section-type") or 0),
            "place": int(_prop(row, "place-type") or 0),
            "device": device,
            "visible": row.get_visible(),
        })
    return out


# ── modo de visualização (lista/grade) ──

def _files_view(slot):
    return find_first(slot, lambda w: gtype_name(w) == "NautilusFilesView")


def view_mode(slot) -> str | None:
    """'list' ou 'grid' conforme o widget que o Nautilus está mostrando agora."""
    root = _files_view(slot) or slot
    for w in walk(root):
        name = gtype_name(w)
        if name == "NautilusGridView":
            return "grid"
        if name == "NautilusListView":
            return "list"
    return None


def set_view_mode(slot, mode: str) -> bool:
    """Leva o slot para 'list' ou 'grid' usando a ação nativa de alternância."""
    current = view_mode(slot)
    if current is None or current == mode:
        return False
    ok = slot.activate_action("slot.files-view-mode-toggle", None)
    debug(f"set_view_mode {current}->{mode} via toggle ok={ok}")
    return bool(ok)


def zoom_in(widget) -> None:
    widget.activate_action("view.zoom-in", None)


def preview_with_sushi(widget) -> bool:
    """Mesma coisa que apertar Espaço no Nautilus."""
    return bool(widget.activate_action("view.preview-selection", None))


# ── seleção (NautilusViewModel é um Gtk.SelectionModel) ──

def find_model(slot):
    root = _files_view(slot) or slot
    for w in walk(root):
        if isinstance(w, (Gtk.ColumnView, Gtk.ListView, Gtk.GridView)):
            model = w.get_model()
            if model is not None and gtype_name(model) == "NautilusViewModel":
                return model
    return None


def _item_uri(item) -> str | None:
    if isinstance(item, Gtk.TreeListRow):
        item = item.get_item()
    if item is None:
        return None
    try:
        info = item.get_property("file")
    except TypeError:
        return None
    try:
        return info.get_uri() if info is not None else None
    except Exception:  # noqa: BLE001
        return None


def selected_uris(model, limit: int = 2000) -> list[str]:
    if model is None:
        return []
    bitset = model.get_selection()
    out = []
    n = min(bitset.get_size(), limit)
    for i in range(n):
        uri = _item_uri(model.get_item(bitset.get_nth(i)))
        if uri:
            out.append(uri)
    return out


def neighbor_uris(model, offsets=(1, -1, 2, -2)) -> list[str]:
    """Itens ao redor do único item selecionado (para pré-carregar o preview)."""
    if model is None:
        return []
    bitset = model.get_selection()
    if bitset.get_size() != 1:
        return []
    pos = bitset.get_nth(0)
    n = model.get_n_items()
    out = []
    for d in offsets:
        p = pos + d
        if 0 <= p < n:
            uri = _item_uri(model.get_item(p))
            if uri:
                out.append(uri)
    return out


def select_uris(model, uris: list[str]) -> bool:
    """Seleciona (e retorna True se achou) os itens com estes URIs no modelo nativo."""
    if model is None or not uris:
        return False
    wanted = {Gio.File.new_for_uri(u).get_uri() for u in uris}
    n = model.get_n_items()
    sel = Gtk.Bitset.new_empty()
    found = False
    for pos in range(n):
        uri = _item_uri(model.get_item(pos))
        if uri in wanted:
            sel.add(pos)
            found = True
    if found:
        model.set_selection(sel, Gtk.Bitset.new_range(0, n))
    return found


class ModelWatch:
    """Um handler de 'selection-changed' no modelo nativo, sem segurá-lo vivo."""

    def __init__(self, callback) -> None:
        self._callback = callback
        self._ref = None
        self._handler = 0

    def get(self):
        return self._ref() if self._ref is not None else None

    def bind(self, model) -> bool:
        if model is not None and model == self.get():
            return False
        self.unbind()
        if model is not None:
            self._ref = model.weak_ref(self._on_finalized)
            self._handler = model.connect("selection-changed", self._on_changed)
            debug("ModelWatch: ligado a novo NautilusViewModel")
        return True

    def unbind(self) -> None:
        model = self.get()
        if model is not None and self._handler:
            try:
                model.disconnect(self._handler)
            except Exception:  # noqa: BLE001
                pass
        self._ref = None
        self._handler = 0

    def _on_finalized(self, *_a) -> None:
        self._ref = None
        self._handler = 0

    def _on_changed(self, model, _pos, _n) -> None:
        try:
            self._callback(model)
        except Exception as err:  # noqa: BLE001
            log(f"ModelWatch callback: {err}")
