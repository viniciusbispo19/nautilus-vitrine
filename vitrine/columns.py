"""Modo Colunas (estilo Finder) em formato híbrido.

À esquerda ficam colunas leves com as pastas-pai do local atual. A pasta atual
continua sendo mostrada pela própria visualização em lista do Nautilus, então
menus de contexto, renomear, arrastar e soltar, scripts e extensões continuam
funcionando nela, sem nada reimplementado.
"""

from __future__ import annotations

import os

from gi.repository import Gdk, Gio, GLib, GObject, Gtk, Pango

from . import util
from .util import guarded

ATTRS = ",".join(
    (
        "standard::name",
        "standard::display-name",
        "standard::type",
        "standard::icon",
        "standard::symbolic-icon",
        "standard::is-hidden",
        "standard::is-backup",
        "standard::content-type",
        "standard::target-uri",
    )
)


def _info_file(info: Gio.FileInfo) -> Gio.File | None:
    f = info.get_attribute_object("standard::file")
    return f if isinstance(f, Gio.File) else None


def _is_dir(info: Gio.FileInfo) -> bool:
    return info.get_file_type() in (Gio.FileType.DIRECTORY, Gio.FileType.MOUNTABLE)


def chain_for(location: Gio.File) -> list[Gio.File]:
    """Pastas-pai a mostrar como colunas: da raiz (Pasta pessoal ou /) até o pai do local atual."""
    home = Gio.File.new_for_path(os.path.expanduser("~"))
    chain = []
    f = location.get_parent()
    while f is not None:
        chain.append(f)
        if f.equal(home):
            break
        f = f.get_parent()
    chain.reverse()
    # Se o local está dentro da pasta pessoal, a primeira coluna é a pasta pessoal.
    if not (location.has_prefix(home) or location.equal(home)):
        return chain
    return [c for c in chain if c.equal(home) or c.has_prefix(home)]


class FolderColumn(Gtk.Box):
    """Uma coluna: lista o conteúdo de uma pasta e destaca o item que está no caminho."""

    __gtype_name__ = "VitrineFolderColumn"

    def __init__(self, strip: "ColumnStrip", folder: Gio.File) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.strip = strip
        self.folder = folder
        self.highlight_uri: str | None = None
        self._programmatic = False
        self._pending_nav = 0
        self.add_css_class("vitrine-column")
        self.set_size_request(strip.column_width, -1)
        self.set_hexpand(False)

        self.dirlist = Gtk.DirectoryList.new(ATTRS, folder)
        self.dirlist.set_monitored(True)
        self.filter = Gtk.CustomFilter.new(self._filter_func, None)
        filtered = Gtk.FilterListModel.new(self.dirlist, self.filter)
        self.sorter = Gtk.CustomSorter.new(self._compare, None)
        sorted_model = Gtk.SortListModel.new(filtered, self.sorter)
        self.selection = Gtk.SingleSelection.new(sorted_model)
        self.selection.set_autoselect(False)
        self.selection.set_can_unselect(True)
        self.selection.connect("selection-changed", self._on_selection_changed)
        sorted_model.connect("items-changed", self._on_items_changed)

        factory = Gtk.SignalListItemFactory()
        factory.connect("setup", self._on_setup)
        factory.connect("bind", self._on_bind)
        self.view = Gtk.ListView.new(self.selection, factory)
        self.view.add_css_class("navigation-sidebar")
        self.view.add_css_class("vitrine-list")
        self.view.connect("activate", self._on_activate)

        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroller.set_vexpand(True)
        scroller.set_child(self.view)
        self.append(scroller)

        # Clique no espaço vazio da coluna = abrir esta pasta (igual ao Finder).
        bg = Gtk.GestureClick.new()
        bg.set_propagation_phase(Gtk.PropagationPhase.BUBBLE)
        bg.connect("released", self._on_background_click)
        scroller.add_controller(bg)

        # Soltar arquivos no fundo da coluna = mover para esta pasta.
        self._add_drop_target(self, lambda: self.folder.get_uri())

    # ── modelo ──
    def _filter_func(self, info, *_a) -> bool:
        if self.strip.show_hidden:
            return True
        return not (info.get_is_hidden() or info.get_is_backup())

    def _compare(self, a, b, *_a) -> int:
        da, db = _is_dir(a), _is_dir(b)
        if da != db:
            return Gtk.Ordering.SMALLER if da else Gtk.Ordering.LARGER
        ka = GLib.utf8_collate_key_for_filename(a.get_display_name(), -1)
        kb = GLib.utf8_collate_key_for_filename(b.get_display_name(), -1)
        if ka < kb:
            return Gtk.Ordering.SMALLER
        if ka > kb:
            return Gtk.Ordering.LARGER
        return Gtk.Ordering.EQUAL

    def refilter(self) -> None:
        self.filter.changed(Gtk.FilterChange.DIFFERENT)

    def set_highlight(self, uri: str | None) -> None:
        self.highlight_uri = uri
        self._apply_highlight()

    @guarded
    def _on_items_changed(self, *_a) -> None:
        # A lista carrega de forma assíncrona; reaplica o destaque quando o item aparece.
        if self.highlight_uri and self.selection.get_selected_item() is None:
            self._apply_highlight()

    def _apply_highlight(self) -> None:
        model = self.selection.get_model()
        target = None
        if self.highlight_uri:
            for pos in range(model.get_n_items()):
                f = _info_file(model.get_item(pos))
                if f is not None and f.get_uri() == self.highlight_uri:
                    target = pos
                    break
        self._programmatic = True
        try:
            if target is None:
                self.selection.set_selected(Gtk.INVALID_LIST_POSITION)
            else:
                self.selection.set_selected(target)
                self.view.scroll_to(target, Gtk.ListScrollFlags.NONE, None)
        finally:
            self._programmatic = False

    # ── linhas ──
    def _on_setup(self, _factory, item: Gtk.ListItem) -> None:
        row = Gtk.Box(spacing=8)
        row.add_css_class("vitrine-row")
        icon = Gtk.Image()
        icon.set_pixel_size(16)
        label = Gtk.Label(xalign=0, hexpand=True)
        label.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        arrow = Gtk.Image.new_from_icon_name("go-next-symbolic")
        arrow.add_css_class("dim-label")
        row.append(icon)
        row.append(label)
        row.append(arrow)
        item.set_child(row)

        # Clique num item que já está destacado (ex.: pasta-pai no caminho) volta para ele.
        primary = Gtk.GestureClick.new()
        primary.set_button(Gdk.BUTTON_PRIMARY)
        primary.connect("released", self._on_row_primary_release, item)
        row.add_controller(primary)

        right = Gtk.GestureClick.new()
        right.set_button(Gdk.BUTTON_SECONDARY)
        right.connect("pressed", self._on_row_right_click, item)
        row.add_controller(right)

        middle = Gtk.GestureClick.new()
        middle.set_button(Gdk.BUTTON_MIDDLE)
        middle.connect("pressed", lambda *_a, it=item: self._open_new_window(it))
        row.add_controller(middle)

        drag = Gtk.DragSource.new()
        drag.set_actions(Gdk.DragAction.COPY | Gdk.DragAction.MOVE)
        drag.connect("prepare", self._on_drag_prepare, item)
        row.add_controller(drag)

        self._add_drop_target(row, lambda it=item: self._drop_dest_for(it))

    def _on_bind(self, _factory, item: Gtk.ListItem) -> None:
        info = item.get_item()
        row = item.get_child()
        icon = row.get_first_child()
        label = icon.get_next_sibling()
        arrow = label.get_next_sibling()
        gicon = info.get_icon() or info.get_symbolic_icon()
        if gicon is not None:
            icon.set_from_gicon(gicon)
        label.set_text(info.get_display_name())
        arrow.set_visible(_is_dir(info))
        row.set_tooltip_text(info.get_display_name())

    # ── interação ──
    @guarded
    def _on_selection_changed(self, *_a) -> None:
        if self._programmatic:
            return
        info = self.selection.get_selected_item()
        if info is None:
            return
        f = _info_file(info)
        if f is None:
            return
        self.highlight_uri = f.get_uri()
        # Pequeno atraso: navegar com as setas não recarrega a cada tecla.
        if self._pending_nav:
            GLib.source_remove(self._pending_nav)
        self._pending_nav = GLib.timeout_add(140, self._commit_nav, info)

    @guarded
    def _commit_nav(self, info) -> bool:
        self._pending_nav = 0
        f = _info_file(info)
        if f is None:
            return GLib.SOURCE_REMOVE
        if _is_dir(info):
            target = info.get_attribute_string("standard::target-uri") or f.get_uri()
            self.strip.navigate(target)
        else:
            # Arquivo numa coluna anterior: abre a pasta dele e seleciona o arquivo.
            self.strip.reveal(self.folder.get_uri(), f.get_uri())
        return GLib.SOURCE_REMOVE

    @guarded
    def _on_activate(self, _view, position: int) -> None:
        info = self.selection.get_model().get_item(position)
        f = _info_file(info) if info is not None else None
        if f is not None and not _is_dir(info):
            util.open_uri(f.get_uri())

    @guarded
    def _on_background_click(self, gesture, n_press, x, y) -> None:
        host = gesture.get_widget()
        picked = host.pick(x, y, Gtk.PickFlags.DEFAULT)
        # Só reage se o clique não caiu numa linha.
        w = picked
        while w is not None and w is not host:
            if w.has_css_class("vitrine-row"):
                return
            w = w.get_parent()
        if n_press == 1:
            self.strip.navigate(self.folder.get_uri())

    @guarded
    def _on_row_primary_release(self, _gesture, n_press, _x, _y, item: Gtk.ListItem) -> None:
        if n_press != 1 or self._pending_nav:
            return
        info = item.get_item()
        if info is None:
            return
        f = _info_file(info)
        if f is not None and item.get_selected() and f.get_uri() == self.highlight_uri:
            GLib.idle_add(self._commit_nav, info)

    def _item_file(self, item: Gtk.ListItem) -> tuple[Gio.FileInfo | None, Gio.File | None]:
        info = item.get_item()
        return info, (_info_file(info) if info is not None else None)

    def _open_new_window(self, item: Gtk.ListItem) -> None:
        info, f = self._item_file(item)
        if f is not None and _is_dir(info):
            util.show_in_new_window(f.get_uri())

    @guarded
    def _on_row_right_click(self, gesture, _n, x, y, item: Gtk.ListItem) -> None:
        info, f = self._item_file(item)
        if f is None:
            return
        gesture.set_state(Gtk.EventSequenceState.CLAIMED)
        uri = f.get_uri()
        is_dir = _is_dir(info)
        row = gesture.get_widget()

        group = Gio.SimpleActionGroup()
        actions = {
            "open": lambda: self.strip.navigate(uri) if is_dir else util.open_uri(uri),
            "new-window": lambda: util.show_in_new_window(uri if is_dir else self.folder.get_uri()),
            "reveal": lambda: self.strip.reveal(self.folder.get_uri(), uri),
            "copy-path": lambda: util.copy_text_to_clipboard(row, f.get_path() or uri),
            "trash": lambda: util.trash_uris([uri]),
        }
        for name, fn in actions.items():
            act = Gio.SimpleAction.new(name, None)
            act.connect("activate", lambda *_a, fn=fn: fn())
            group.add_action(act)
        row.insert_action_group("vcol", group)

        menu = Gio.Menu()
        top = Gio.Menu()
        top.append("Abrir", "vcol.open")
        top.append("Abrir em nova janela", "vcol.new-window")
        top.append("Mostrar na lista (todas as ações do Nautilus)", "vcol.reveal")
        menu.append_section(None, top)
        mid = Gio.Menu()
        mid.append("Copiar caminho", "vcol.copy-path")
        menu.append_section(None, mid)
        end = Gio.Menu()
        end.append("Mover para a lixeira", "vcol.trash")
        menu.append_section(None, end)

        pop = Gtk.PopoverMenu.new_from_model(menu)
        pop.set_parent(row)
        pop.set_has_arrow(False)
        rect = Gdk.Rectangle()
        rect.x, rect.y, rect.width, rect.height = int(x), int(y), 1, 1
        pop.set_pointing_to(rect)
        pop.connect("closed", lambda p: GLib.idle_add(p.unparent))
        pop.popup()

    # ── arrastar e soltar ──
    @guarded
    def _on_drag_prepare(self, _src, _x, _y, item: Gtk.ListItem):
        _info, f = self._item_file(item)
        if f is None:
            return None
        flist = Gdk.FileList.new_from_list([f])
        value = GObject.Value()
        value.init(Gdk.FileList)
        value.set_boxed(flist)
        return Gdk.ContentProvider.new_for_value(value)

    def _drop_dest_for(self, item: Gtk.ListItem) -> str | None:
        info, f = self._item_file(item)
        if f is None:
            return None
        return f.get_uri() if _is_dir(info) else self.folder.get_uri()

    def _add_drop_target(self, widget: Gtk.Widget, dest_getter) -> None:
        target = Gtk.DropTarget.new(Gdk.FileList, Gdk.DragAction.COPY | Gdk.DragAction.MOVE)

        @guarded
        def on_drop(tgt, value, _x, _y):
            dest = dest_getter()
            if not dest or value is None:
                return False
            uris = [g.get_uri() for g in value.get_files()]
            uris = [u for u in uris if Gio.File.new_for_uri(u).get_parent() is None
                    or Gio.File.new_for_uri(u).get_parent().get_uri() != dest]
            if not uris:
                return False
            drop = tgt.get_current_drop()
            action = drop.get_actions() if drop is not None else Gdk.DragAction.MOVE
            if action & Gdk.DragAction.MOVE:
                util.move_uris(uris, dest)
            else:
                util.copy_uris(uris, dest)
            return True

        target.connect("drop", on_drop)
        widget.add_controller(target)


class ColumnStrip(Gtk.Box):
    """A faixa de colunas que fica à esquerda da lista nativa."""

    __gtype_name__ = "VitrineColumnStrip"

    def __init__(self, *, column_width: int, max_visible: int, on_navigate, on_reveal) -> None:
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL)
        self.add_css_class("vitrine-strip")
        self.column_width = column_width
        self.max_visible = max(1, max_visible)
        self._on_navigate = on_navigate
        self._on_reveal = on_reveal
        self.columns: list[FolderColumn] = []
        self.location: Gio.File | None = None
        self._nautilus_prefs = Gio.Settings.new("org.gnome.nautilus.preferences")
        self.show_hidden = self._nautilus_prefs.get_boolean("show-hidden-files")
        self._hidden_handler = self._nautilus_prefs.connect(
            "changed::show-hidden-files", self._on_hidden_changed)

        self.scroller = Gtk.ScrolledWindow()
        self.scroller.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER)
        self.scroller.set_hexpand(False)
        self.box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        self.scroller.set_child(self.box)
        self.append(self.scroller)
        self.append(Gtk.Separator(orientation=Gtk.Orientation.VERTICAL))

    def teardown(self) -> None:
        if self._hidden_handler:
            self._nautilus_prefs.disconnect(self._hidden_handler)
            self._hidden_handler = 0
        self.set_location(None)

    @guarded
    def _on_hidden_changed(self, settings, key) -> None:
        self.show_hidden = settings.get_boolean(key)
        for col in self.columns:
            col.refilter()

    def navigate(self, uri: str) -> None:
        self._on_navigate(uri)

    def reveal(self, folder_uri: str, file_uri: str) -> None:
        self._on_reveal(folder_uri, file_uri)

    def set_location(self, location: Gio.File | None) -> None:
        """Reconstrói as colunas reaproveitando as que não mudaram (evita recarregar)."""
        self.location = location
        chain = chain_for(location) if location is not None else []
        keep = 0
        while (keep < len(chain) and keep < len(self.columns)
               and self.columns[keep].folder.equal(chain[keep])):
            keep += 1
        for col in self.columns[keep:]:
            self.box.remove(col)
            sep = col._vitrine_sep
            if sep is not None:
                self.box.remove(sep)
        self.columns = self.columns[:keep]
        for folder in chain[keep:]:
            col = FolderColumn(self, folder)
            sep = Gtk.Separator(orientation=Gtk.Orientation.VERTICAL)
            col._vitrine_sep = sep
            self.box.append(col)
            self.box.append(sep)
            self.columns.append(col)
        # Destaque: em cada coluna, o próximo elemento do caminho.
        path = chain + ([location] if location is not None else [])
        for i, col in enumerate(self.columns):
            nxt = path[i + 1] if i + 1 < len(path) else None
            col.set_highlight(nxt.get_uri() if nxt is not None else None)

        n = len(self.columns)
        visible = min(n, self.max_visible)
        self.scroller.set_size_request(visible * (self.column_width + 1), -1)
        self.set_visible(n > 0)
        GLib.idle_add(self._scroll_to_end)

    def _scroll_to_end(self) -> bool:
        adj = self.scroller.get_hadjustment()
        adj.set_value(max(0.0, adj.get_upper() - adj.get_page_size()))
        return GLib.SOURCE_REMOVE
