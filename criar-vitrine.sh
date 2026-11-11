#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  criar-vitrine.sh — cria o projeto "Vitrine para Nautilus" (Fedora / GNOME)
#
#  Uso:
#     bash criar-vitrine.sh                 # cria em ~/nautilus-vitrine
#     bash criar-vitrine.sh ~/Projetos/vit  # cria na pasta indicada
#     bash criar-vitrine.sh --instalar      # cria e já instala no Nautilus
#
#  Depois:  code ~/nautilus-vitrine   (abre no VS Code; Ctrl+Shift+B instala)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TARGET="$HOME/nautilus-vitrine"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --instalar|--install) INSTALL=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) TARGET="$arg" ;;
  esac
done

if [[ -e "$TARGET" && -n "$(ls -A "$TARGET" 2>/dev/null)" ]]; then
  read -r -p "A pasta $TARGET já existe e não está vazia. Sobrescrever os arquivos da Vitrine? [s/N] " ans
  [[ "${ans:-N}" =~ ^[SsYy]$ ]] || { echo "Cancelado."; exit 1; }
fi
mkdir -p "$TARGET"
cd "$TARGET"
echo "Criando arquivos em $TARGET …"

cat > 'nautilus-vitrine.py' <<'__VITRINE_ARQUIVO_0__'
"""Vitrine para Nautilus: modo Colunas, pré-visualização lateral e visualização por pasta.

Este arquivo é o que o nautilus-python carrega. O código de verdade fica no
pacote `vitrine/` ao lado dele.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from vitrine.main import VitrineExtension  # noqa: E402,F401
__VITRINE_ARQUIVO_0__
mkdir -p "vitrine"
cat > 'vitrine/__init__.py' <<'__VITRINE_ARQUIVO_1__'
"""Vitrine para Nautilus."""
__VITRINE_ARQUIVO_1__
mkdir -p "vitrine"
cat > 'vitrine/columns.py' <<'__VITRINE_ARQUIVO_2__'
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
__VITRINE_ARQUIVO_2__
mkdir -p "vitrine"
cat > 'vitrine/config.py' <<'__VITRINE_ARQUIVO_3__'
"""Preferências e regras de visualização por pasta (JSON em ~/.config/nautilus-vitrine)."""

from __future__ import annotations

import json
import os

from gi.repository import Gio, GLib

from .util import log

CONFIG_DIR = os.path.join(GLib.get_user_config_dir(), "nautilus-vitrine")
SETTINGS_PATH = os.path.join(CONFIG_DIR, "settings.json")
FOLDERS_PATH = os.path.join(CONFIG_DIR, "folders.json")

MODES = ("list", "grid", "columns")
GRID_ZOOMS = ("small", "small-plus", "medium", "large", "extra-large")

DEFAULT_SETTINGS = {
    # Painel de pré-visualização à direita (Ctrl+Shift+P).
    "preview_visible": True,
    "preview_width": 320,
    # Largura de cada coluna no modo Colunas.
    "column_width": 230,
    # Quantas colunas anteriores aparecem antes de começar a rolar.
    "max_visible_columns": 3,
    # Ao trocar a visualização numa pasta, guardar a escolha para aquela pasta.
    "remember_per_folder": True,
    # Pastas cheias de fotos/vídeos abrem em ícones grandes automaticamente.
    "auto_media_grid": True,
    "auto_media_zoom": "extra-large",
    "auto_media_ratio": 0.6,
    # Visualização para pastas sem regra. None = capturar do Nautilus na 1ª execução.
    "default_mode": None,
    "default_grid_zoom": None,
}


def _load_json(path: str, fallback):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return fallback
    except (OSError, ValueError) as err:
        log(f"config: {path} ilegível ({err}); usando padrão")
        return fallback


def _norm(uri: str) -> str:
    return Gio.File.new_for_uri(uri).get_uri()


class Config:
    def __init__(self) -> None:
        self.settings = dict(DEFAULT_SETTINGS)
        self.settings.update(_load_json(SETTINGS_PATH, {}))
        raw = _load_json(FOLDERS_PATH, {})
        self.folders: dict[str, dict] = {k: v for k, v in raw.items() if isinstance(v, dict)}
        self._save_id = 0
        self._seed_defaults()

    def _seed_defaults(self) -> None:
        changed = False
        if self.settings.get("default_mode") not in MODES:
            try:
                viewer = Gio.Settings.new("org.gnome.nautilus.preferences").get_string(
                    "default-folder-viewer"
                )
            except Exception:  # noqa: BLE001
                viewer = "list-view"
            self.settings["default_mode"] = "grid" if viewer == "icon-view" else "list"
            changed = True
        if self.settings.get("default_grid_zoom") not in GRID_ZOOMS:
            try:
                zoom = Gio.Settings.new("org.gnome.nautilus.icon-view").get_string(
                    "default-zoom-level"
                )
            except Exception:  # noqa: BLE001
                zoom = "medium"
            self.settings["default_grid_zoom"] = zoom if zoom in GRID_ZOOMS else "medium"
            changed = True
        if not self.folders:
            self._seed_pictures_rule()
            changed = True
        if changed:
            self.save()

    def _seed_pictures_rule(self) -> None:
        """Na primeira execução: a pasta Imagens (XDG) começa em ícones grandes."""
        for special in (GLib.UserDirectory.DIRECTORY_PICTURES, GLib.UserDirectory.DIRECTORY_VIDEOS):
            path = GLib.get_user_special_dir(special)
            if path and os.path.isdir(path) and os.path.realpath(path) != os.path.expanduser("~"):
                uri = Gio.File.new_for_path(path).get_uri()
                self.folders[uri] = {"mode": "grid", "zoom": "extra-large", "recursive": True}

    # ── leitura ──
    def get(self, key: str):
        return self.settings.get(key, DEFAULT_SETTINGS.get(key))

    def set(self, key: str, value) -> None:
        self.settings[key] = value
        self.save()

    def rule_for(self, uri: str) -> tuple[dict | None, bool]:
        """Regra que vale para `uri`: (regra, é_exata). Sobe pelas pastas-pai
        procurando uma regra marcada como "aplicar às subpastas"."""
        uri = _norm(uri)
        rule = self.folders.get(uri)
        if rule:
            return rule, True
        f = Gio.File.new_for_uri(uri).get_parent()
        while f is not None:
            r = self.folders.get(f.get_uri())
            if r and r.get("recursive"):
                return r, False
            f = f.get_parent()
        return None, False

    # ── escrita ──
    def set_rule(self, uri: str, *, mode: str | None = None, zoom: str | None = None,
                 recursive: bool | None = None) -> dict:
        uri = _norm(uri)
        rule = dict(self.folders.get(uri) or {})
        if mode is not None:
            rule["mode"] = mode
        if zoom is not None:
            rule["zoom"] = zoom
        if recursive is not None:
            rule["recursive"] = recursive
        rule.setdefault("mode", self.get("default_mode"))
        self.folders[uri] = rule
        self.save()
        log(f"regra salva: {uri} -> {rule}")
        return rule

    def forget(self, uri: str) -> None:
        if self.folders.pop(_norm(uri), None) is not None:
            self.save()
            log(f"regra removida: {uri}")

    def save(self) -> None:
        """Grava em disco de forma agrupada (no máximo 1x a cada 400 ms)."""
        if self._save_id:
            return
        self._save_id = GLib.timeout_add(400, self._flush)

    def _flush(self) -> bool:
        self._save_id = 0
        try:
            os.makedirs(CONFIG_DIR, exist_ok=True)
            for path, data in ((SETTINGS_PATH, self.settings), (FOLDERS_PATH, self.folders)):
                tmp = path + ".tmp"
                with open(tmp, "w", encoding="utf-8") as fh:
                    json.dump(data, fh, indent=2, ensure_ascii=False)
                os.replace(tmp, path)
        except OSError as err:
            log(f"config: falha ao salvar ({err})")
        return GLib.SOURCE_REMOVE
__VITRINE_ARQUIVO_3__
mkdir -p "vitrine"
cat > 'vitrine/imageload.py' <<'__VITRINE_ARQUIVO_4__'
"""Carregamento rápido de imagens para o preview.

No Fedora 45 o gdk-pixbuf usa o glycin, que abre um processo isolado (sandbox)
para cada imagem: ~50 ms só para ler as dimensões e ~70 ms+ para decodificar.
Aqui:

* JPEG/PNG/TIFF vão pelo decodificador interno do GTK (sem sandbox, ~3x mais rápido);
* dimensões e rotação EXIF são lidas direto do cabeçalho do arquivo, em Python;
* só fotos rotacionadas, gigantes ou de outros formatos (WebP, HEIC, AVIF…) usam o glycin;
* imagens já vistas ficam num cache; as vizinhas são pré-carregadas.
"""

from __future__ import annotations

import os
import struct
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor

import gi

gi.require_version("Gdk", "4.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, Gio  # noqa: E402

FAST_TYPES = ("image/jpeg", "image/png", "image/tiff")
FAST_MAX_PIXELS = 40_000_000  # acima disso, decodifica já reduzida (economiza memória)
SCALED_MAX_PX = 1600
HEADER_BYTES = 256 * 1024

EXECUTOR = ThreadPoolExecutor(max_workers=2, thread_name_prefix="vitrine-img")


class Probe:
    __slots__ = ("width", "height", "orientation")

    def __init__(self, width=0, height=0, orientation=1) -> None:
        self.width, self.height, self.orientation = width, height, orientation


def _probe_jpeg(data: bytes) -> Probe:
    p = Probe()
    if data[:2] != b"\xff\xd8":
        return p
    i = 2
    n = len(data)
    while i + 4 <= n:
        if data[i] != 0xFF:
            break
        marker = data[i + 1]
        if marker == 0xFF:  # bytes de preenchimento
            i += 1
            continue
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        if marker in (0xD9, 0xDA):  # fim da imagem / início dos dados
            break
        seg_len = struct.unpack(">H", data[i + 2:i + 4])[0]
        seg = data[i + 4:i + 2 + seg_len]
        if marker == 0xE1 and seg[:6] == b"Exif\x00\x00":
            p.orientation = _exif_orientation(seg[6:]) or 1
        elif marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            if len(seg) >= 5:
                p.height, p.width = struct.unpack(">HH", seg[1:5])
            break
        i += 2 + seg_len
    return p


def _exif_orientation(tiff: bytes) -> int:
    if len(tiff) < 8 or tiff[:2] not in (b"II", b"MM"):
        return 1
    e = "<" if tiff[:2] == b"II" else ">"
    ifd = struct.unpack(e + "I", tiff[4:8])[0]
    if ifd + 2 > len(tiff):
        return 1
    count = struct.unpack(e + "H", tiff[ifd:ifd + 2])[0]
    for k in range(count):
        off = ifd + 2 + 12 * k
        if off + 12 > len(tiff):
            break
        if struct.unpack(e + "H", tiff[off:off + 2])[0] == 0x0112:
            return struct.unpack(e + "H", tiff[off + 8:off + 10])[0]
    return 1


def probe(path: str, ct: str) -> Probe:
    """Dimensões e orientação lidas do cabeçalho, sem decodificar a imagem."""
    try:
        with open(path, "rb") as fh:
            data = fh.read(HEADER_BYTES if ct == "image/jpeg" else 64)
    except OSError:
        return Probe()
    if ct == "image/jpeg":
        return _probe_jpeg(data)
    if ct == "image/png" and data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR":
        w, h = struct.unpack(">II", data[16:24])
        return Probe(w, h, 1)
    return Probe()


def guess_type(path: str) -> str:
    ct, _uncertain = Gio.content_type_guess(path, None)
    return ct or ""


def cache_key(path: str):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (path, st.st_mtime_ns, st.st_size)


def load(path: str, ct: str):
    """Roda numa thread. Devolve (textura, largura_original, altura_original)."""
    pr = probe(path, ct)
    pixels = pr.width * pr.height
    if ct in FAST_TYPES and pr.orientation == 1 and pixels <= FAST_MAX_PIXELS:
        tex = Gdk.Texture.new_from_filename(path)
        return tex, (pr.width or tex.get_width()), (pr.height or tex.get_height())
    # Caminho lento (glycin): foto girada pelo EXIF, gigante ou formato não-nativo.
    pix = GdkPixbuf.Pixbuf.new_from_file_at_scale(path, SCALED_MAX_PX, SCALED_MAX_PX, True)
    pix = pix.apply_embedded_orientation() or pix
    w, h = pr.width, pr.height
    if pr.orientation in (5, 6, 7, 8):
        w, h = h, w
    return Gdk.Texture.new_for_pixbuf(pix), w, h


class TextureCache:
    """LRU em memória, limitado por quantidade e por total de pixels."""

    def __init__(self, max_items: int = 24, max_pixels: int = 160_000_000) -> None:
        self._items: OrderedDict = OrderedDict()
        self._max_items = max_items
        self._max_pixels = max_pixels
        self._pixels = 0

    def get(self, key):
        val = self._items.get(key)
        if val is not None:
            self._items.move_to_end(key)
        return val

    def __contains__(self, key) -> bool:
        return key in self._items

    def put(self, key, val) -> None:
        if key is None or key in self._items:
            return
        tex = val[0]
        self._items[key] = val
        self._pixels += tex.get_width() * tex.get_height()
        while self._items and (len(self._items) > self._max_items or self._pixels > self._max_pixels):
            _k, (old, _w, _h) = self._items.popitem(last=False)
            self._pixels -= old.get_width() * old.get_height()


CACHE = TextureCache()


def best_thumbnail(info: Gio.FileInfo) -> str | None:
    """A maior miniatura que o Nautilus/GNOME já gerou para o arquivo (carrega em ~1 ms)."""
    for suffix in ("-xxlarge", "-xlarge", "-large", "", "-normal"):
        path = info.get_attribute_byte_string(f"thumbnail::path{suffix}")
        if not path:
            continue
        valid_attr = f"thumbnail::is-valid{suffix}"
        if info.has_attribute(valid_attr) and not info.get_attribute_boolean(valid_attr):
            continue
        if os.path.exists(path):
            return path
    return None


THUMB_ATTRS = ",".join(
    f"thumbnail::{k}{s}"
    for s in ("", "-normal", "-large", "-xlarge", "-xxlarge")
    for k in ("path", "is-valid")
)
__VITRINE_ARQUIVO_4__
mkdir -p "vitrine"
cat > 'vitrine/main.py' <<'__VITRINE_ARQUIVO_5__'
"""Ponto central: descobre as janelas do Nautilus e oferece o menu "Visualização desta pasta"."""

from __future__ import annotations

import os
import time

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Nautilus", "4.1")
from gi.repository import Gdk, Gio, GLib, GObject, Gtk, Nautilus  # noqa: E402

from . import native  # noqa: E402
from .config import GRID_ZOOMS, Config  # noqa: E402
from .util import guarded, log  # noqa: E402
from .window import WindowController  # noqa: E402

VERSION = "0.1.0"

CSS = b"""
.vitrine-strip { background-color: var(--view-bg-color); }
.vitrine-column listview.vitrine-list { background: transparent; }
.vitrine-column listview.vitrine-list > row { margin: 1px 4px; padding: 4px 6px; }
.vitrine-preview { background-color: var(--sidebar-bg-color); }
.vitrine-picture { border-radius: 10px; }
"""


_ACTIVE_INSTANCE = None


class VitrineExtension(GObject.GObject, Nautilus.MenuProvider):
    def __init__(self) -> None:
        global _ACTIVE_INSTANCE
        super().__init__()
        # Instalada duas vezes (RPM em /usr/share + cópia de desenvolvimento em ~/.local)?
        # O nautilus-python carrega as duas; só a primeira instância trabalha.
        self._inert = _ACTIVE_INSTANCE is not None
        if self._inert:
            log("outra cópia da Vitrine já está ativa; esta instância fica inativa")
            return
        _ACTIVE_INSTANCE = self
        self.cfg = Config()
        self.windows: dict = {}
        self._suppress_until = 0.0
        self._attempts = 0
        self._css_done = False
        self.selftest_started = False
        self.debug_dump = os.environ.get("VITRINE_DUMP", "") not in ("", "0")
        self._prefs = Gio.Settings.new("org.gnome.nautilus.preferences")
        self._icon_prefs = Gio.Settings.new("org.gnome.nautilus.icon-view")
        self._icon_prefs.connect("changed::default-zoom-level", self._on_zoom_changed)
        log(f"Vitrine {VERSION} carregada")
        GLib.timeout_add(100, self._late_init)

    # ── janelas ──
    @guarded
    def _late_init(self) -> bool:
        app = Gtk.Application.get_default()
        if app is None:
            self._attempts += 1
            return self._attempts < 100
        app.connect("window-added", lambda _a, w: self._schedule(w))
        for w in app.get_windows():
            self._schedule(w)
        return GLib.SOURCE_REMOVE

    def _install_css(self) -> None:
        if self._css_done:
            return
        display = Gdk.Display.get_default()
        if display is None:
            return
        provider = Gtk.CssProvider()
        provider.load_from_bytes(GLib.Bytes.new(CSS))
        Gtk.StyleContext.add_provider_for_display(
            display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self._css_done = True

    def _schedule(self, win) -> None:
        if win in self.windows or not native.is_nautilus_window(win):
            return
        tries = [0]

        def attempt() -> bool:
            tries[0] += 1
            if win in self.windows:
                return GLib.SOURCE_REMOVE
            slot = native.active_slot(win)
            ready = slot is not None and native.slot_location(slot) is not None
            if not ready and tries[0] < 100:
                return GLib.SOURCE_CONTINUE
            # Prioridade baixa: deixa o Nautilus terminar o primeiro carregamento antes
            # de mexermos na árvore de widgets.
            GLib.idle_add(self._inject, win, priority=GLib.PRIORITY_LOW)
            return GLib.SOURCE_REMOVE

        GLib.timeout_add(50, attempt)

    @guarded
    def _inject(self, win) -> bool:
        if win in self.windows:
            return GLib.SOURCE_REMOVE
        self._install_css()
        ctl = WindowController(self, win)
        if ctl.inject():
            self.windows[win] = ctl
        return GLib.SOURCE_REMOVE

    def forget_window(self, win) -> None:
        self.windows.pop(win, None)

    def active_controller(self) -> WindowController | None:
        app = Gtk.Application.get_default()
        win = app.get_active_window() if app is not None else None
        ctl = self.windows.get(win)
        if ctl is None and self.windows:
            ctl = next(iter(self.windows.values()))
        return ctl

    # ── supressão: mudanças feitas por nós não contam como escolha do usuário ──
    def suppress(self, ms: int = 900) -> None:
        self._suppress_until = max(self._suppress_until, time.monotonic() + ms / 1000)

    def is_suppressed(self) -> bool:
        return time.monotonic() < self._suppress_until

    def current_grid_zoom(self) -> str:
        z = self._icon_prefs.get_string("default-zoom-level")
        return z if z in GRID_ZOOMS else "medium"

    def set_grid_zoom(self, zoom: str | None) -> None:
        if zoom not in GRID_ZOOMS or self.current_grid_zoom() == zoom:
            return
        self.suppress()
        self._icon_prefs.set_string("default-zoom-level", zoom)

    @guarded
    def _on_zoom_changed(self, settings, key) -> None:
        if self.is_suppressed():
            return
        ctl = self.active_controller()
        if ctl is not None:
            ctl.record_zoom(settings.get_string(key))

    # ── menu de contexto no fundo da pasta (API oficial do Nautilus) ──
    def get_file_items(self, *args):
        return []

    @guarded
    def get_background_items(self, *args):
        folder = args[-1] if args else None
        if folder is None or self._inert:
            return []
        uri = folder.get_uri()
        if not native.is_regular_location(uri):
            return []
        rule, exact = self.cfg.rule_for(uri)

        root = Nautilus.MenuItem(name="Vitrine::root", label="Visualização desta pasta")
        sub = Nautilus.Menu()
        root.set_submenu(sub)

        def add(name, label, cb):
            item = Nautilus.MenuItem(name=f"Vitrine::{name}", label=label)
            item.connect("activate", lambda *_a: GLib.idle_add(self._run, cb))
            sub.append_item(item)

        add("list", "Lista", lambda c: c.user_set_mode("list"))
        add("grid", "Ícones", lambda c: c.user_set_mode("grid", "medium"))
        add("grid-large", "Ícones grandes", lambda c: c.user_set_mode("grid", "extra-large"))
        add("columns", "Colunas", lambda c: c.user_set_mode("columns"))

        if exact and rule:
            if rule.get("recursive"):
                add("norec", "Não aplicar às subpastas",
                    lambda c: self.cfg.set_rule(uri, recursive=False))
            else:
                add("rec", "Aplicar também às subpastas",
                    lambda c: self.cfg.set_rule(uri, recursive=True))
            add("forget", "Esquecer esta pasta (usar o padrão)", lambda c: self._forget(c, uri))
        elif rule:
            add("info", "(herdando a regra de uma pasta acima)", lambda c: None)

        add("default", "Usar a visualização atual como padrão", self._make_default)
        add("preview", "Mostrar/ocultar pré-visualização (Ctrl+Shift+P)",
            lambda c: c.set_preview_visible(not c.preview.get_visible()))
        return [root]

    def _run(self, cb) -> bool:
        ctl = self.active_controller()
        if ctl is not None:
            try:
                cb(ctl)
            except Exception as err:  # noqa: BLE001
                log(f"menu: {err}")
        return GLib.SOURCE_REMOVE

    def _forget(self, ctl: WindowController, uri: str) -> None:
        self.cfg.forget(uri)
        slot = ctl.active_slot()
        if slot is not None:
            slot._vitrine_mode = None
            ctl._apply_rule_for_slot(slot, native.slot_uri(slot))

    def _make_default(self, ctl: WindowController) -> None:
        slot = ctl.active_slot()
        mode = getattr(slot, "_vitrine_mode", None) or native.view_mode(slot) or "list"
        self.cfg.set("default_mode", mode)
        if mode == "grid":
            self.cfg.set("default_grid_zoom", self.current_grid_zoom())
        log(f"novo padrão: {mode}")
__VITRINE_ARQUIVO_5__
mkdir -p "vitrine"
cat > 'vitrine/native.py' <<'__VITRINE_ARQUIVO_6__'
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
__VITRINE_ARQUIVO_6__
mkdir -p "vitrine"
cat > 'vitrine/preview.py' <<'__VITRINE_ARQUIVO_7__'
"""Painel de pré-visualização à direita: imagem, texto, miniatura de vídeo/PDF e informações."""

from __future__ import annotations

import threading

import gi

from gi.repository import Gdk, Gio, GLib, Gtk, Pango  # noqa: E402

from . import imageload, util  # noqa: E402
from .util import guarded, log  # noqa: E402

try:
    gi.require_version("GnomeDesktop", "4.0")
    from gi.repository import GnomeDesktop  # noqa: E402

    _THUMB_FACTORY = GnomeDesktop.DesktopThumbnailFactory.new(
        GnomeDesktop.DesktopThumbnailSize.XLARGE
    )
except Exception:  # noqa: BLE001
    _THUMB_FACTORY = None

INFO_ATTRS = ",".join(
    (
        "standard::*",
        "time::modified",
        "time::created",
        "time::access",
        imageload.THUMB_ATTRS,
        "access::can-read",
        "unix::mode",
        "owner::user",
    )
)
PREFETCH_MAX = 4
TEXT_MAX_BYTES = 256 * 1024
TEXT_MAX_LINES = 400
FOLDER_LIST_MAX = 300


def _is_text(ct: str) -> bool:
    return bool(ct) and (
        Gio.content_type_is_a(ct, "text/plain")
        or ct in ("application/json", "application/xml", "application/x-yaml",
                  "application/toml", "application/javascript", "application/x-shellscript")
    )


class PreviewPane(Gtk.Box):
    __gtype_name__ = "VitrinePreviewPane"

    def __init__(self, *, on_navigate, on_reveal, on_quicklook) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.add_css_class("vitrine-preview")
        self._on_navigate = on_navigate
        self._on_reveal = on_reveal
        self._on_quicklook = on_quicklook
        self._cancel: Gio.Cancellable | None = None
        self._token = 0
        self._current_uri: str | None = None
        self._folder_uri: str | None = None
        self._pending = 0

        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroller.set_vexpand(True)
        self.append(scroller)

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        body.set_margin_top(18)
        body.set_margin_bottom(18)
        body.set_margin_start(16)
        body.set_margin_end(16)
        scroller.set_child(body)

        # Área de mídia: imagem / ícone / texto / conteúdo da pasta.
        self.media = Gtk.Stack()
        self.media.set_transition_type(Gtk.StackTransitionType.NONE)
        self._inflight: set = set()

        self.picture = Gtk.Picture()
        self.picture.set_can_shrink(True)
        self.picture.set_content_fit(Gtk.ContentFit.CONTAIN)
        self.picture.set_size_request(-1, 240)
        self.picture.add_css_class("vitrine-picture")
        pic_click = Gtk.GestureClick.new()
        pic_click.connect("released", lambda g, n, *_: n == 2 and self._open_current())
        self.picture.add_controller(pic_click)
        self.media.add_named(self.picture, "picture")

        self.icon = Gtk.Image()
        self.icon.set_pixel_size(128)
        self.icon.set_margin_top(12)
        self.icon.set_margin_bottom(12)
        self.media.add_named(self.icon, "icon")

        self.text = Gtk.TextView()
        self.text.set_editable(False)
        self.text.set_cursor_visible(False)
        self.text.set_monospace(True)
        self.text.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.text.set_top_margin(8)
        self.text.set_bottom_margin(8)
        self.text.set_left_margin(8)
        self.text.set_right_margin(8)
        text_scroll = Gtk.ScrolledWindow()
        text_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        text_scroll.set_size_request(-1, 320)
        text_scroll.set_child(self.text)
        text_scroll.add_css_class("card")
        self.media.add_named(text_scroll, "text")

        self.folder_list = Gtk.ListBox()
        self.folder_list.add_css_class("boxed-list")
        self.folder_list.set_selection_mode(Gtk.SelectionMode.NONE)
        self.folder_list.connect("row-activated", self._on_folder_row)
        folder_scroll = Gtk.ScrolledWindow()
        folder_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        folder_scroll.set_size_request(-1, 300)
        folder_scroll.set_child(self.folder_list)
        self.media.add_named(folder_scroll, "folder")
        body.append(self.media)

        self.title = Gtk.Label(wrap=True, justify=Gtk.Justification.CENTER, selectable=True)
        self.title.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
        self.title.set_max_width_chars(28)
        self.title.add_css_class("title-3")
        body.append(self.title)

        self.subtitle = Gtk.Label(wrap=True, justify=Gtk.Justification.CENTER)
        self.subtitle.add_css_class("dim-label")
        body.append(self.subtitle)

        buttons = Gtk.Box(spacing=8, halign=Gtk.Align.CENTER)
        self.open_btn = Gtk.Button(label="Abrir")
        self.open_btn.add_css_class("pill")
        self.open_btn.add_css_class("suggested-action")
        self.open_btn.connect("clicked", lambda *_: self._open_current())
        self.look_btn = Gtk.Button(icon_name="view-reveal-symbolic", tooltip_text="Visualização rápida (Espaço)")
        self.look_btn.add_css_class("circular")
        self.look_btn.connect("clicked", lambda *_: self._on_quicklook())
        buttons.append(self.open_btn)
        buttons.append(self.look_btn)
        body.append(buttons)

        self.info = Gtk.Grid(column_spacing=12, row_spacing=6)
        self.info.set_margin_top(6)
        body.append(Gtk.Separator())
        body.append(self.info)

    # ── API ──
    def set_folder(self, folder_uri: str | None) -> None:
        self._folder_uri = folder_uri

    def show_uris(self, uris, prefetch=None) -> None:
        """Agenda a atualização (agrupa seleções rápidas, ex. segurar a seta).

        `uris` pode ser uma lista ou uma função que devolve a lista. A função é lida
        só na hora de mostrar, para não exibir uma seleção intermediária (por exemplo,
        enquanto o Nautilus reordena os itens ao trocar lista/grade)."""
        if self._pending:
            GLib.source_remove(self._pending)
        self._pending = GLib.timeout_add(
            30, self._apply, uris if callable(uris) else list(uris), prefetch)

    # ── internos ──
    def _new_token(self) -> int:
        if self._cancel is not None:
            self._cancel.cancel()
        self._cancel = Gio.Cancellable()
        self._token += 1
        return self._token

    @guarded
    def _apply(self, uris, prefetch=None) -> bool:
        self._pending = 0
        if callable(uris):
            uris = uris()
        if prefetch is not None:
            GLib.idle_add(self._prefetch, prefetch, priority=GLib.PRIORITY_LOW)
        token = self._new_token()
        if len(uris) > 1:
            self._show_multi(uris, token)
        elif len(uris) == 1:
            self._show_one(uris[0], token, selected=True)
        elif self._folder_uri:
            self._show_one(self._folder_uri, token, selected=False)
        else:
            self._clear()
        return GLib.SOURCE_REMOVE

    def _clear(self) -> None:
        self._current_uri = None
        self.icon.set_from_icon_name("folder-symbolic")
        self.media.set_visible_child_name("icon")
        self.title.set_text("")
        self.subtitle.set_text("")
        self.open_btn.set_visible(False)
        self.look_btn.set_visible(False)
        self._set_rows([])

    def _set_rows(self, rows: list[tuple[str, str]]) -> None:
        child = self.info.get_first_child()
        while child is not None:
            nxt = child.get_next_sibling()
            self.info.remove(child)
            child = nxt
        for i, (key, value) in enumerate(rows):
            k = Gtk.Label(label=key, xalign=1, yalign=0)
            k.add_css_class("dim-label")
            v = Gtk.Label(label=value, xalign=0, wrap=True, selectable=True, hexpand=True)
            v.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
            v.set_max_width_chars(24)
            self.info.attach(k, 0, i, 1, 1)
            self.info.attach(v, 1, i, 1, 1)

    def _show_one(self, uri: str, token: int, *, selected: bool) -> None:
        self._current_uri = uri
        gfile = Gio.File.new_for_uri(uri)
        gfile.query_info_async(
            INFO_ATTRS, Gio.FileQueryInfoFlags.NONE, GLib.PRIORITY_DEFAULT, self._cancel,
            self._on_info, (token, gfile, selected),
        )

    @guarded
    def _on_info(self, gfile: Gio.File, result, data) -> None:
        token, _f, selected = data
        try:
            info = gfile.query_info_finish(result)
        except GLib.Error as err:
            if token == self._token and not err.matches(Gio.io_error_quark(), Gio.IOErrorEnum.CANCELLED):
                self._clear()
                self.title.set_text(gfile.get_basename() or "")
                self.subtitle.set_text(err.message)
            return
        if token != self._token:
            return

        ct = info.get_content_type() or ""
        ftype = info.get_file_type()
        is_dir = ftype == Gio.FileType.DIRECTORY
        self.title.set_text(info.get_display_name())
        desc = "Pasta" if is_dir else (Gio.content_type_get_description(ct) if ct else "")
        self.open_btn.set_visible(selected)
        self.open_btn.set_label("Abrir pasta" if is_dir else "Abrir")
        self.look_btn.set_visible(selected)

        rows = [("Tipo", desc or "—")]
        if not is_dir:
            rows.append(("Tamanho", util.human_size(info.get_size())))
        rows.append(("Modificado", util.format_time(info.get_modification_date_time())))
        created = info.get_creation_date_time() if info.has_attribute("time::created") else None
        if created is not None:
            rows.append(("Criado", util.format_time(created)))
        path = gfile.get_path()
        parent = gfile.get_parent()
        if parent is not None:
            rows.append(("Local", parent.get_path() or parent.get_uri()))
        self._set_rows(rows)
        self.subtitle.set_text(desc if is_dir else f"{desc} · {util.human_size(info.get_size())}")

        if is_dir:
            self._show_folder_contents(gfile, token, rows)
        elif ct.startswith("image/") and path:
            self._show_image(path, ct, info, token, rows)
        elif _is_text(ct) and info.get_size() <= TEXT_MAX_BYTES:
            self._show_icon(info)
            gfile.load_contents_async(self._cancel, self._on_text, token)
        else:
            self._show_thumbnail(gfile, info, token)

    def _show_icon(self, info: Gio.FileInfo) -> None:
        gicon = info.get_icon()
        if gicon is not None:
            self.icon.set_from_gicon(gicon)
        else:
            self.icon.set_from_icon_name("text-x-generic")
        self.media.set_visible_child_name("icon")

    # imagens: miniatura na hora → imagem nítida em seguida (cache + pré-carregamento)
    def _show_image(self, path: str, ct: str, info: Gio.FileInfo, token: int, rows: list) -> None:
        key = imageload.cache_key(path)
        hit = imageload.CACHE.get(key) if key is not None else None
        if hit is not None:
            self._present_image(hit, rows)
            return
        thumb = imageload.best_thumbnail(info)
        shown = False
        if thumb:
            try:
                self.picture.set_paintable(Gdk.Texture.new_from_filename(thumb))
                self.media.set_visible_child_name("picture")
                shown = True
            except GLib.Error:
                pass
        if not shown:
            self._show_icon(info)
        self._submit(key, path, ct, token, rows)

    def _submit(self, key, path: str, ct: str, token: int | None, rows: list | None) -> None:
        """token=None é pré-carregamento (só enche o cache)."""
        if key is None or key in self._inflight:
            return
        self._inflight.add(key)

        def work():
            if token is not None and token != self._token:
                GLib.idle_add(self._inflight.discard, key)
                return  # o usuário já foi para outro arquivo
            try:
                val = imageload.load(path, ct)
            except Exception as err:  # noqa: BLE001
                log(f"preview: imagem {path}: {err}")
                GLib.idle_add(self._inflight.discard, key)
                return
            GLib.idle_add(self._image_loaded, key, val, token, rows)

        imageload.EXECUTOR.submit(work)

    @guarded
    def _image_loaded(self, key, val, token, rows) -> bool:
        self._inflight.discard(key)
        imageload.CACHE.put(key, val)
        if token is not None and token == self._token:
            self._present_image(val, rows)
        return GLib.SOURCE_REMOVE

    def _present_image(self, val, rows: list) -> None:
        tex, w, h = val
        self.picture.set_paintable(tex)
        self.media.set_visible_child_name("picture")
        if w and h:
            self._set_rows(rows[:1] + [("Dimensões", f"{w} × {h} px")] + rows[1:])

    @guarded
    def _prefetch(self, fn) -> bool:
        uris = fn() if callable(fn) else fn
        for uri in (uris or [])[:PREFETCH_MAX]:
            path = Gio.File.new_for_uri(uri).get_path()
            if not path:
                continue
            ct = imageload.guess_type(path)
            if not ct.startswith("image/"):
                continue
            key = imageload.cache_key(path)
            if key is not None and key not in imageload.CACHE:
                self._submit(key, path, ct, None, None)
        return GLib.SOURCE_REMOVE

    # texto
    @guarded
    def _on_text(self, gfile, result, token) -> None:
        try:
            ok, data, _etag = gfile.load_contents_finish(result)
        except GLib.Error:
            return
        if token != self._token or not ok:
            return
        text = data.decode("utf-8", errors="replace")
        lines = text.splitlines()
        if len(lines) > TEXT_MAX_LINES:
            text = "\n".join(lines[:TEXT_MAX_LINES]) + "\n…"
        self.text.get_buffer().set_text(text)
        self.media.set_visible_child_name("text")

    # vídeo, PDF, documentos: miniatura do sistema
    def _show_thumbnail(self, gfile: Gio.File, info: Gio.FileInfo, token: int) -> None:
        self._show_icon(info)
        thumb = imageload.best_thumbnail(info)
        if thumb:
            try:
                self.picture.set_paintable(Gdk.Texture.new_from_filename(thumb))
                self.media.set_visible_child_name("picture")
                return
            except GLib.Error:
                pass
        if _THUMB_FACTORY is None:
            return
        uri = gfile.get_uri()
        ct = info.get_content_type() or ""
        mtime = info.get_modification_date_time()
        mtime_s = mtime.to_unix() if mtime is not None else 0

        def work():
            try:
                if not _THUMB_FACTORY.can_thumbnail(uri, ct, mtime_s):
                    return
                pix = _THUMB_FACTORY.generate_thumbnail(uri, ct, None)
                if pix is None:
                    return
                _THUMB_FACTORY.save_thumbnail(pix, uri, mtime_s, None)
                tex = Gdk.Texture.new_for_pixbuf(pix)
                GLib.idle_add(self._thumb_ready, token, tex)
            except Exception as err:  # noqa: BLE001
                log(f"preview: miniatura {uri}: {err}")

        threading.Thread(target=work, daemon=True).start()

    @guarded
    def _thumb_ready(self, token, tex) -> bool:
        if token == self._token:
            self.picture.set_paintable(tex)
            self.media.set_visible_child_name("picture")
        return GLib.SOURCE_REMOVE

    # pastas: lista do conteúdo (como a próxima coluna do Finder)
    def _show_folder_contents(self, gfile: Gio.File, token: int, rows: list) -> None:
        self.icon.set_from_icon_name("folder")
        self.media.set_visible_child_name("icon")
        gfile.enumerate_children_async(
            "standard::name,standard::display-name,standard::icon,standard::type,standard::is-hidden",
            Gio.FileQueryInfoFlags.NONE, GLib.PRIORITY_DEFAULT, self._cancel,
            self._on_enum, (token, rows, []),
        )

    @guarded
    def _on_enum(self, gfile, result, data) -> None:
        token, rows, acc = data
        try:
            enum = gfile.enumerate_children_finish(result)
        except GLib.Error:
            return
        enum.next_files_async(100, GLib.PRIORITY_DEFAULT, self._cancel, self._on_batch,
                              (token, rows, acc, gfile))

    @guarded
    def _on_batch(self, enum, result, data) -> None:
        token, rows, acc, folder = data
        try:
            infos = enum.next_files_finish(result)
        except GLib.Error:
            return
        if token != self._token:
            enum.close_async(GLib.PRIORITY_LOW, None, None)
            return
        acc.extend(i for i in infos if not i.get_is_hidden())
        if infos and len(acc) < 5000:
            enum.next_files_async(200, GLib.PRIORITY_DEFAULT, self._cancel, self._on_batch, data)
            return
        enum.close_async(GLib.PRIORITY_LOW, None, None)
        n_dirs = sum(1 for i in acc if i.get_file_type() == Gio.FileType.DIRECTORY)
        n_files = len(acc) - n_dirs
        self.subtitle.set_text(f"{len(acc)} itens · {n_dirs} pastas, {n_files} arquivos")
        self._set_rows([("Conteúdo", f"{len(acc)} itens")] + rows)

        while (row := self.folder_list.get_row_at_index(0)) is not None:
            self.folder_list.remove(row)
        acc.sort(key=lambda i: (i.get_file_type() != Gio.FileType.DIRECTORY,
                                GLib.utf8_collate_key_for_filename(i.get_display_name(), -1)))
        if not acc:
            return
        for info in acc[:FOLDER_LIST_MAX]:
            row = Gtk.ListBoxRow()
            box = Gtk.Box(spacing=8)
            box.set_margin_top(4)
            box.set_margin_bottom(4)
            box.set_margin_start(8)
            box.set_margin_end(8)
            img = Gtk.Image()
            if info.get_icon() is not None:
                img.set_from_gicon(info.get_icon())
            lbl = Gtk.Label(label=info.get_display_name(), xalign=0, hexpand=True)
            lbl.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
            box.append(img)
            box.append(lbl)
            row.set_child(box)
            row._vitrine_uri = folder.get_child(info.get_name()).get_uri()
            row._vitrine_dir = info.get_file_type() == Gio.FileType.DIRECTORY
            row._vitrine_parent = folder.get_uri()
            self.folder_list.append(row)
        self.media.set_visible_child_name("folder")

    @guarded
    def _on_folder_row(self, _lb, row) -> None:
        uri = getattr(row, "_vitrine_uri", None)
        if not uri:
            return
        if getattr(row, "_vitrine_dir", False):
            self._on_navigate(uri)
        else:
            self._on_reveal(row._vitrine_parent, uri)

    # várias seleções
    def _show_multi(self, uris: list[str], token: int) -> None:
        self._current_uri = None
        self.icon.set_from_icon_name("edit-select-all-symbolic")
        self.media.set_visible_child_name("icon")
        self.title.set_text(f"{len(uris)} itens selecionados")
        self.subtitle.set_text("Calculando tamanho…")
        self.open_btn.set_visible(False)
        self.look_btn.set_visible(True)
        self._set_rows([])

        def work():
            total = 0
            for u in uris[:2000]:
                try:
                    i = Gio.File.new_for_uri(u).query_info("standard::size,standard::type",
                                                           Gio.FileQueryInfoFlags.NONE, None)
                    if i.get_file_type() != Gio.FileType.DIRECTORY:
                        total += i.get_size()
                except GLib.Error:
                    pass
                if token != self._token:
                    return
            GLib.idle_add(self._multi_ready, token, total)

        threading.Thread(target=work, daemon=True).start()

    @guarded
    def _multi_ready(self, token, total) -> bool:
        if token == self._token:
            self.subtitle.set_text(f"{util.human_size(total)} em arquivos (sem contar subpastas)")
        return GLib.SOURCE_REMOVE

    def _open_current(self) -> None:
        if not self._current_uri:
            return
        f = Gio.File.new_for_uri(self._current_uri)
        if f.query_file_type(Gio.FileQueryInfoFlags.NONE, None) == Gio.FileType.DIRECTORY:
            self._on_navigate(self._current_uri)
        else:
            util.open_uri(self._current_uri)
__VITRINE_ARQUIVO_7__
mkdir -p "vitrine"
cat > 'vitrine/selftest.py' <<'__VITRINE_ARQUIVO_8__'
"""Autoteste dentro do Nautilus real. Só roda com VITRINE_SELFTEST=1.

Navega por pastas, troca modos, seleciona arquivos e grava PASSOU/FALHOU no log.
No final restaura as regras e o zoom que existiam antes.
"""

from __future__ import annotations

import copy
import os
import time

from gi.repository import Gio, GLib

from . import imageload, native
from .util import log

STEP_MS = 1500


def _image_uris(model) -> list[str]:
    out = []
    if model is None:
        return out
    for pos in range(model.get_n_items()):
        uri = native._item_uri(model.get_item(pos))
        path = Gio.File.new_for_uri(uri).get_path() if uri else None
        if path and imageload.guess_type(path) in imageload.FAST_TYPES:
            out.append(uri)
        if len(out) >= 3:
            break
    return out


def _time_preview(ctl, uri: str, label: str, check) -> None:
    """Seleciona `uri` na lista nativa e mede: 1ª imagem visível e imagem nítida."""
    path = Gio.File.new_for_uri(uri).get_path()
    key = imageload.cache_key(path)
    before = ctl.preview.picture.get_paintable()
    t0 = time.monotonic()
    marks = {}
    native.select_uris(native.find_model(ctl.active_slot()), [uri])

    def poll():
        now = (time.monotonic() - t0) * 1000
        pic = ctl.preview.picture.get_paintable()
        on_picture = ctl.preview.media.get_visible_child_name() == "picture"
        if "first" not in marks and on_picture and pic is not None and pic is not before:
            marks["first"] = now
        hit = imageload.CACHE.get(key)
        if hit is not None and pic is hit[0] and on_picture:
            marks.setdefault("first", now)
            marks["full"] = now
        if "full" in marks or now > 1300:
            full = marks.get("full")
            check(f"preview {label}", full is not None and full < 600,
                  f"{os.path.basename(path)}: 1ª imagem={marks.get('first', -1):.0f} ms, "
                  f"nítida={full if full is not None else -1:.0f} ms")
            return GLib.SOURCE_REMOVE
        return GLib.SOURCE_CONTINUE

    GLib.timeout_add(5, poll)


def run(ctl) -> bool:
    cfg = ctl.cfg
    saved_folders = copy.deepcopy(cfg.folders)
    saved_settings = copy.deepcopy(cfg.settings)
    saved_zoom = ctl.ext.current_grid_zoom()
    home = Gio.File.new_for_path(os.path.expanduser("~")).get_uri()
    pictures = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_PICTURES)
    pictures_uri = Gio.File.new_for_path(pictures).get_uri() if pictures else None
    project = Gio.File.new_for_path(os.path.join(os.path.dirname(os.path.dirname(
        os.path.realpath(__file__))), "vitrine")).get_uri()
    results: list[tuple[str, bool, str]] = []
    images: list[str] = []

    def check(name, ok, detail=""):
        results.append((name, bool(ok), detail))
        log(f"SELFTEST {'PASSOU' if ok else 'FALHOU'}: {name} {detail}")

    def slot():
        return ctl.active_slot()

    def state():
        s = slot()
        return {
            "uri": native.slot_uri(s),
            "view": native.view_mode(s),
            "vmode": getattr(s, "_vitrine_mode", None),
            "strip": ctl.strip.get_visible(),
            "cols": [c.folder.get_basename() for c in ctl.strip.columns],
            "zoom": ctl.ext.current_grid_zoom(),
            "preview": (ctl.preview.get_visible(), ctl.preview.media.get_visible_child_name(),
                        ctl.preview.title.get_text()),
        }

    steps = []

    def step(fn):
        steps.append(fn)
        return fn

    @step
    def s0():
        st = state()
        check("injeção (botões e painel existem)",
              ctl.btn_columns is not None and ctl.btn_columns.get_root() is ctl.win
              and ctl.preview.get_root() is ctl.win, str(st))
        ctl.navigate(home)

    @step
    def s1():
        st = state()
        check("pasta pessoal abre em lista", st["view"] == "list" and not st["strip"], str(st))
        check("preview mostra a pasta atual sem seleção",
              st["preview"][0] and st["preview"][2] != "", str(st["preview"]))
        if pictures_uri:
            ctl.navigate(pictures_uri)

    @step
    def s2():
        st = state()
        if pictures_uri:
            check("Imagens abre em ícones grandes", st["view"] == "grid" and st["zoom"] == "extra-large",
                  str(st))
            images.extend(_image_uris(native.find_model(slot())))
            if images:
                _time_preview(ctl, images[0], "1ª foto (sem cache)", check)

    @step
    def s2b():
        if len(images) > 1:
            _time_preview(ctl, images[1], "foto vizinha (pré-carregada)", check)

    @step
    def s2c():
        if images:
            _time_preview(ctl, images[0], "voltar à 1ª foto (cache)", check)

    @step
    def s2d():
        ctl.navigate(home)

    @step
    def s3():
        st = state()
        check("voltando para a pasta pessoal, volta para lista", st["view"] == "list", str(st))
        ctl.navigate(project)

    @step
    def s4():
        st = state()
        check("pasta do projeto abre (sem regra) em lista", st["view"] == "list", str(st))
        ctl.user_set_mode("columns")

    @step
    def s5():
        st = state()
        check("Ctrl+3 / Colunas liga as colunas",
              st["strip"] and st["vmode"] == "columns" and st["view"] == "list"
              and st["cols"][-1:] == ["nautilus-vitrine"], str(st))
        check("botão de colunas fica ativo", ctl.btn_columns.get_active())
        model = native.find_model(slot())
        main_py = Gio.File.new_for_uri(project).get_child("main.py").get_uri()
        check("seleção nativa por URI", native.select_uris(model, [main_py]))

    @step
    def s6():
        st = state()
        check("preview acompanha a seleção da lista nativa",
              st["preview"][2] == "main.py" and st["preview"][1] == "text", str(st["preview"]))
        parent = Gio.File.new_for_uri(project).get_parent().get_uri()
        ctl.navigate(parent)

    @step
    def s7():
        st = state()
        check("navegar continua em colunas (sem regra)", st["strip"] and st["vmode"] == "columns",
              str(st))
        ctl.navigate(project)

    @step
    def s8():
        st = state()
        check("pasta lembrada em colunas", st["vmode"] == "columns", str(st))
        ctl.user_set_mode("list")

    @step
    def s9():
        st = state()
        check("Ctrl+1 sai das colunas", not st["strip"] and st["view"] == "list", str(st))
        ctl.user_set_mode("grid", "large")

    @step
    def s10():
        st = state()
        check("trocar para ícones aplica e lembra o zoom",
              st["view"] == "grid" and st["zoom"] == "large"
              and (cfg.folders.get(Gio.File.new_for_uri(project).get_uri()) or {}).get("zoom") == "large",
              str(st))
        sel = native.selected_uris(native.find_model(slot()))
        expected = Gio.File.new_for_uri(sel[0]).get_basename() if len(sel) == 1 else None
        check("preview mostra a mesma seleção do Nautilus depois de trocar para ícones",
              expected is None or st["preview"][2] == expected,
              f"preview={st['preview']} nativo={sel}")
        ctl.navigate(home)

    @step
    def s11():
        st = state()
        check("regra não vaza para outras pastas", st["view"] == "list", str(st))
        # restaura tudo
        cfg.folders.clear()
        cfg.folders.update(saved_folders)
        cfg.settings.clear()
        cfg.settings.update(saved_settings)
        cfg.save()
        ctl.ext.set_grid_zoom(saved_zoom)
        ok = sum(1 for r in results if r[1])
        log(f"SELFTEST RESUMO: {ok}/{len(results)} passaram")

    def runner(i=[0]):
        if i[0] >= len(steps):
            return GLib.SOURCE_REMOVE
        try:
            steps[i[0]]()
        except Exception as err:  # noqa: BLE001
            check(f"passo {i[0]} gerou exceção", False, repr(err))
        i[0] += 1
        return GLib.SOURCE_CONTINUE

    GLib.timeout_add(STEP_MS, runner)
    return GLib.SOURCE_REMOVE
__VITRINE_ARQUIVO_8__
mkdir -p "vitrine"
cat > 'vitrine/util.py' <<'__VITRINE_ARQUIVO_9__'
"""Utilitários: log, varredura da árvore de widgets e operações de arquivo nativas."""

from __future__ import annotations

import functools
import os
import time
import traceback

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, GObject, Gtk  # noqa: E402

LOG_DIR = os.path.join(GLib.get_user_cache_dir(), "nautilus-vitrine")
LOG_PATH = os.path.join(LOG_DIR, "vitrine.log")
DEBUG = os.environ.get("VITRINE_DEBUG", "") not in ("", "0")
_LOG_MAX_BYTES = 512 * 1024


def log(msg: str) -> None:
    """Escreve uma linha em ~/.cache/nautilus-vitrine/vitrine.log."""
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > _LOG_MAX_BYTES:
            os.replace(LOG_PATH, LOG_PATH + ".1")
        with open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass


def debug(msg: str) -> None:
    if DEBUG:
        log("[debug] " + msg)


def guarded(fn):
    """Envolve callbacks de sinal: uma exceção vira linha de log, nunca derruba o Nautilus."""

    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except Exception:  # noqa: BLE001
            log(f"ERRO em {fn.__qualname__}:\n{traceback.format_exc()}")
            return None

    return wrapper


def gtype_name(obj) -> str:
    try:
        return GObject.type_name(obj.__gtype__)
    except Exception:  # noqa: BLE001
        return type(obj).__name__


def walk(widget):
    """Percorre o widget e todos os descendentes (profundidade primeiro)."""
    if widget is None:
        return
    stack = [widget]
    while stack:
        w = stack.pop()
        yield w
        children = []
        child = w.get_first_child()
        while child is not None:
            children.append(child)
            child = child.get_next_sibling()
        stack.extend(reversed(children))


def find_first(root, pred):
    for w in walk(root):
        try:
            if pred(w):
                return w
        except Exception:  # noqa: BLE001
            continue
    return None


def find_by_type_name(root, name: str):
    return find_first(root, lambda w: gtype_name(w) == name)


def ancestor(widget, pred):
    w = widget.get_parent() if widget is not None else None
    while w is not None:
        if pred(w):
            return w
        w = w.get_parent()
    return None


def dump_tree(root, max_depth: int = 18) -> str:
    """Árvore de widgets em texto (para depuração em versões novas do Nautilus)."""
    lines = []

    def rec(w, depth):
        if depth > max_depth:
            return
        bid = ""
        try:
            bid = w.get_buildable_id() or ""
        except Exception:  # noqa: BLE001
            pass
        css = ",".join(w.get_css_classes() or [])
        lines.append(f"{'  ' * depth}{gtype_name(w)} id={bid!r} css=[{css}] vis={w.get_visible()}")
        c = w.get_first_child()
        while c is not None:
            rec(c, depth + 1)
            c = c.get_next_sibling()

    rec(root, 0)
    return "\n".join(lines)


def is_tab_view(w) -> bool:
    return isinstance(w, Adw.TabView)


def is_toolbar_view(w) -> bool:
    return isinstance(w, Adw.ToolbarView)


# ── Operações de arquivo do próprio Nautilus (D-Bus) ─────────────────────────
# Usar a API FileOperations2 do Nautilus em vez de Gio direto mantém o
# comportamento nativo: barra de progresso, diálogos de conflito e Desfazer (Ctrl+Z).

_FILE_OPS_BUS = "org.gnome.Nautilus"
_FILE_OPS_PATH = "/org/gnome/Nautilus/FileOperations2"
_FILE_OPS_IFACE = "org.gnome.Nautilus.FileOperations2"


def _platform_data() -> dict:
    return {"timestamp": GLib.Variant("u", 0)}


def file_operation(method: str, args: tuple, signature: str) -> None:
    """Chama um método de FileOperations2 de forma assíncrona."""

    def on_done(conn, result):
        try:
            conn.call_finish(result)
        except GLib.Error as err:
            log(f"FileOperations2.{method} falhou: {err.message}")

    def on_bus(_src, result):
        try:
            conn = Gio.bus_get_finish(result)
        except GLib.Error as err:
            log(f"sem barramento de sessão: {err.message}")
            return
        params = GLib.Variant(f"({signature}a{{sv}})", (*args, _platform_data()))
        conn.call(
            _FILE_OPS_BUS,
            _FILE_OPS_PATH,
            _FILE_OPS_IFACE,
            method,
            params,
            None,
            Gio.DBusCallFlags.NONE,
            -1,
            None,
            on_done,
        )

    Gio.bus_get(Gio.BusType.SESSION, None, on_bus)


def move_uris(uris: list[str], dest_dir_uri: str) -> None:
    file_operation("MoveURIs", (uris, dest_dir_uri), "ass")


def copy_uris(uris: list[str], dest_dir_uri: str) -> None:
    file_operation("CopyURIs", (uris, dest_dir_uri), "ass")


def trash_uris(uris: list[str]) -> None:
    file_operation("TrashURIs", (uris,), "as")


def open_uri(uri: str) -> None:
    """Abre com o aplicativo padrão (igual ao duplo clique do Nautilus)."""

    def done(_src, result):
        try:
            Gio.AppInfo.launch_default_for_uri_finish(result)
        except GLib.Error as err:
            log(f"não foi possível abrir {uri}: {err.message}")

    Gio.AppInfo.launch_default_for_uri_async(uri, None, None, done)


def show_in_new_window(uri: str) -> None:
    """org.freedesktop.FileManager1.ShowFolders — abre uma janela nova do Nautilus."""

    def on_bus(_src, result):
        try:
            conn = Gio.bus_get_finish(result)
        except GLib.Error:
            return
        conn.call(
            "org.freedesktop.FileManager1",
            "/org/freedesktop/FileManager1",
            "org.freedesktop.FileManager1",
            "ShowFolders",
            GLib.Variant("(ass)", ([uri], "")),
            None,
            Gio.DBusCallFlags.NONE,
            -1,
            None,
            None,
        )

    Gio.bus_get(Gio.BusType.SESSION, None, on_bus)


def copy_text_to_clipboard(widget: Gtk.Widget, text: str) -> None:
    widget.get_clipboard().set(text)


def human_size(n: int) -> str:
    return GLib.format_size(n)


def format_time(dt: GLib.DateTime | None) -> str:
    if dt is None:
        return "—"
    return dt.to_local().format("%d/%m/%Y %H:%M")
__VITRINE_ARQUIVO_9__
mkdir -p "vitrine"
cat > 'vitrine/window.py' <<'__VITRINE_ARQUIVO_10__'
"""Controlador por janela: injeta Colunas + Pré-visualização e aplica as regras por pasta."""

from __future__ import annotations

import os

from gi.repository import Adw, Gdk, Gio, GLib, Gtk

from . import native
from .columns import ColumnStrip
from .preview import PreviewPane
from .util import ancestor, debug, dump_tree, find_by_type_name, find_first, gtype_name, guarded, log

_MOD_MASK = (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK
             | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SUPER_MASK)
_MEDIA_SAMPLE = 250


class WindowController:
    def __init__(self, ext, win: Gtk.Window) -> None:
        self.ext = ext
        self.cfg = ext.cfg
        self.win = win
        self.columns_on = False
        self.tab_view: Adw.TabView | None = None
        self.strip: ColumnStrip | None = None
        self.preview: PreviewPane | None = None
        self.paned: Gtk.Paned | None = None
        self.btn_columns: Gtk.ToggleButton | None = None
        self.btn_preview: Gtk.ToggleButton | None = None
        self._syncing_buttons = False
        self._setting_pos = False
        self._pos_initialized = False
        self._reveal_target: tuple[str, str] | None = None
        self._reveal_source = 0
        self._media_cache: dict[str, bool] = {}
        self.model_watch = native.ModelWatch(self._on_native_selection)

    # ───────────────────────── injeção ─────────────────────────
    def inject(self) -> bool:
        if self.ext.debug_dump:
            log("árvore da janela:\n" + dump_tree(self.win))
        tv = native.find_tab_view(self.win)
        if tv is None:
            log("inject: AdwTabView não encontrado; a estrutura do Nautilus mudou")
            return False
        toolbar = ancestor(tv, lambda w: isinstance(w, Adw.ToolbarView))
        if toolbar is None or toolbar.get_content() is not tv:
            log(f"inject: pai inesperado do TabView ({gtype_name(tv.get_parent())})")
            return False
        self.tab_view = tv

        self.strip = ColumnStrip(
            column_width=int(self.cfg.get("column_width")),
            max_visible=int(self.cfg.get("max_visible_columns")),
            on_navigate=self.navigate,
            on_reveal=self.reveal,
        )
        self.strip.set_visible(False)
        self.preview = PreviewPane(
            on_navigate=self.navigate,
            on_reveal=self.reveal,
            on_quicklook=self.quicklook,
        )
        self.preview.set_visible(bool(self.cfg.get("preview_visible")))

        # [colunas | abas do Nautilus]  ‖  [pré-visualização]
        inner = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        toolbar.set_content(None)  # `tv` continua vivo: a referência Python o segura
        tv.set_hexpand(True)
        inner.append(self.strip)
        inner.append(tv)

        self.paned = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        self.paned.set_wide_handle(False)
        self.paned.set_start_child(inner)
        self.paned.set_end_child(self.preview)
        self.paned.set_resize_start_child(True)
        self.paned.set_shrink_start_child(False)
        self.paned.set_resize_end_child(False)
        self.paned.set_shrink_end_child(False)
        self.paned.connect("notify::max-position", self._on_paned_max)
        self.paned.connect("notify::position", self._on_paned_pos)
        toolbar.set_content(self.paned)

        self._inject_buttons()
        self._install_keys()

        tv.connect("notify::selected-page", self._on_tab_switched)
        tv.connect("page-attached", lambda _tv, page, _pos: self._watch_slot(page.get_child()))
        for i in range(tv.get_n_pages()):
            self._watch_slot(tv.get_nth_page(i).get_child())
        self.win.connect("destroy", self._on_destroy)

        GLib.idle_add(self._initial_sync, priority=GLib.PRIORITY_LOW)
        log("janela injetada com sucesso")
        if os.environ.get("VITRINE_SELFTEST", "") not in ("", "0") and not self.ext.selftest_started:
            from . import selftest

            self.ext.selftest_started = True
            GLib.timeout_add(2000, selftest.run, self)
        return True

    def _initial_sync(self) -> bool:
        slot = self.active_slot()
        if slot is not None:
            self._on_slot_location(slot)
        return GLib.SOURCE_REMOVE

    def _inject_buttons(self) -> None:
        box = Gtk.Box(spacing=0)
        box.add_css_class("linked")
        self.btn_columns = Gtk.ToggleButton(icon_name="view-dual-symbolic",
                                            tooltip_text="Colunas (Ctrl+3)")
        self.btn_columns.connect("toggled", self._on_btn_columns)
        self.btn_preview = Gtk.ToggleButton(icon_name="sidebar-show-right-symbolic",
                                            tooltip_text="Pré-visualização (Ctrl+Shift+P)")
        self.btn_preview.set_active(bool(self.cfg.get("preview_visible")))
        self.btn_preview.connect("toggled", self._on_btn_preview)
        box.append(self.btn_columns)
        box.append(self.btn_preview)

        toolbar = find_by_type_name(self.win, "NautilusToolbar")
        controls = find_by_type_name(toolbar, "NautilusViewControls") if toolbar else None
        parent = controls.get_parent() if controls is not None else None
        if isinstance(parent, Gtk.Box):
            parent.insert_child_after(box, controls.get_prev_sibling())
            box.set_margin_end(6)
            return
        header = find_first(toolbar or self.win, lambda w: isinstance(w, Adw.HeaderBar))
        if header is not None:
            header.pack_end(box)
            return
        log("inject: nenhum lugar para os botões na barra; use os atalhos")

    def _install_keys(self) -> None:
        keys = Gtk.EventControllerKey()
        keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        keys.connect("key-pressed", self._on_key)
        self.win.add_controller(keys)

    @guarded
    def _on_key(self, _ctrl, keyval, _code, state) -> bool:
        mods = state & _MOD_MASK
        if mods == Gdk.ModifierType.CONTROL_MASK:
            if keyval == Gdk.KEY_3:
                self.user_set_mode("columns")
                return True
            if keyval in (Gdk.KEY_1, Gdk.KEY_2):
                # O Nautilus troca lista/grade sozinho; nós só registramos e saímos das colunas.
                mode = "list" if keyval == Gdk.KEY_1 else "grid"
                GLib.idle_add(self._after_native_key, mode)
                return False
        if mods == (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK) and keyval in (
                Gdk.KEY_P, Gdk.KEY_p):
            self.set_preview_visible(not self.preview.get_visible())
            return True
        return False

    def _after_native_key(self, mode: str) -> bool:
        self.user_set_mode(mode)
        return GLib.SOURCE_REMOVE

    # ───────────────────────── slots / abas ─────────────────────────
    def active_slot(self):
        if self.tab_view is None:
            return None
        page = self.tab_view.get_selected_page()
        return page.get_child() if page is not None else None

    def _watch_slot(self, slot) -> None:
        if slot is None or getattr(slot, "_vitrine_watched", False):
            return
        slot._vitrine_watched = True
        slot.connect("notify::location", lambda s, _p: self._on_slot_location(s))

    @guarded
    def _on_tab_switched(self, *_a) -> None:
        slot = self.active_slot()
        if slot is None:
            return
        self._set_columns_visible(getattr(slot, "_vitrine_mode", None) == "columns")
        self._sync_active_ui(slot)

    @guarded
    def _on_slot_location(self, slot) -> None:
        uri = native.slot_uri(slot)
        if uri is None:
            return
        self.ext.suppress()
        if slot is self.active_slot():
            self._sync_active_ui(slot)
        GLib.idle_add(self._apply_rule_for_slot, slot, uri, priority=GLib.PRIORITY_LOW)

    def _sync_active_ui(self, slot) -> None:
        loc = native.slot_location(slot)
        uri = loc.get_uri() if loc is not None else None
        regular = native.is_regular_location(uri)
        if self.strip is not None:
            self.strip.set_location(loc if (regular and self.columns_on) else None)
            if not self.columns_on:
                self.strip.set_visible(False)
        if self.preview is not None:
            self.preview.set_folder(uri if regular else None)
            self.preview.show_uris([])
        self._rebind_model_soon()

    def _rebind_model_soon(self) -> None:
        for delay in (0, 250, 900):
            GLib.timeout_add(delay, self._rebind_model)

    @guarded
    def _rebind_model(self) -> bool:
        slot = self.active_slot()
        model = native.find_model(slot) if slot is not None else None
        if self.model_watch.bind(model) and model is not None:
            self._on_native_selection(model)
        self._watch_view_switch(slot)
        return GLib.SOURCE_REMOVE

    def _watch_view_switch(self, slot) -> None:
        """Percebe quando o usuário troca lista/grade pelo botão ou menu do próprio Nautilus."""
        fv = find_by_type_name(slot, "NautilusFilesView") if slot is not None else None
        overlay = find_first(fv, lambda w: isinstance(w, Gtk.Overlay)) if fv is not None else None
        if overlay is None or getattr(overlay, "_vitrine_watched", False):
            return
        overlay._vitrine_watched = True
        overlay.connect("notify::child", self._on_native_view_switched)

    @guarded
    def _on_native_view_switched(self, *_a) -> None:
        self._rebind_model_soon()
        if self.ext.is_suppressed():
            return
        GLib.timeout_add(60, self._record_native_mode)

    def _record_native_mode(self) -> bool:
        slot = self.active_slot()
        mode = native.view_mode(slot) if slot is not None else None
        if mode is None:
            return GLib.SOURCE_REMOVE
        if self.columns_on and mode == "list":
            return GLib.SOURCE_REMOVE  # coluna usa lista por baixo; nada mudou de fato
        debug(f"usuário trocou a visualização nativa para {mode}")
        self.user_set_mode(mode)
        return GLib.SOURCE_REMOVE

    # ───────────────────────── seleção / pré-visualização ─────────────────────────
    def _on_native_selection(self, _model) -> None:
        if self.preview is None or not self.preview.get_visible():
            return
        self.preview.show_uris(lambda: native.selected_uris(self.model_watch.get()),
                               prefetch=lambda: native.neighbor_uris(self.model_watch.get()))

    def quicklook(self) -> None:
        native.preview_with_sushi(self.active_slot() or self.win)

    def navigate(self, uri: str) -> None:
        native.open_location(self.active_slot(), uri)

    def reveal(self, folder_uri: str, file_uri: str) -> None:
        """Abre `folder_uri` na lista nativa e seleciona `file_uri` quando carregar."""
        slot = self.active_slot()
        if slot is None:
            return
        if native.slot_uri(slot) != Gio.File.new_for_uri(folder_uri).get_uri():
            native.open_location(slot, folder_uri)
        self._reveal_target = (folder_uri, file_uri)
        if self._reveal_source:
            GLib.source_remove(self._reveal_source)
        tries = [0]

        def attempt() -> bool:
            tries[0] += 1
            s = self.active_slot()
            model = native.find_model(s) if s is not None else None
            if model is not None and native.select_uris(model, [file_uri]):
                self._reveal_source = 0
                return GLib.SOURCE_REMOVE
            if tries[0] > 40:
                self._reveal_source = 0
                return GLib.SOURCE_REMOVE
            return GLib.SOURCE_CONTINUE

        self._reveal_source = GLib.timeout_add(100, attempt)

    # ───────────────────────── modos e regras por pasta ─────────────────────────
    @guarded
    def _apply_rule_for_slot(self, slot, uri: str) -> bool:
        if native.slot_uri(slot) != uri:
            return GLib.SOURCE_REMOVE  # já navegou para outro lugar
        if not native.is_regular_location(uri):
            if slot is self.active_slot():
                self._set_columns_visible(False)
            return GLib.SOURCE_REMOVE
        rule, _exact = self.cfg.rule_for(uri)
        current = getattr(slot, "_vitrine_mode", None)
        if rule:
            self.apply_mode(slot, rule.get("mode", "list"), rule.get("zoom"))
        elif current == "columns":
            self.apply_mode(slot, "columns")  # navegar em colunas continua em colunas
        elif self.cfg.get("auto_media_grid"):
            self._detect_media(slot, uri)
        else:
            self.apply_mode(slot, self.cfg.get("default_mode"))
        return GLib.SOURCE_REMOVE

    def apply_mode(self, slot, mode: str, zoom: str | None = None) -> None:
        if mode not in ("list", "grid", "columns"):
            mode = "list"
        self.ext.suppress()
        slot._vitrine_mode = mode
        if slot is self.active_slot():
            self._set_columns_visible(mode == "columns")
        native.set_view_mode(slot, "list" if mode == "columns" else mode)
        if mode == "grid":
            self.ext.set_grid_zoom(zoom or self.cfg.get("default_grid_zoom"))
        # Confere depois que o Nautilus terminar de trocar a visualização.
        GLib.timeout_add(350, self._verify_mode, slot, mode)

    def _verify_mode(self, slot, mode: str) -> bool:
        if getattr(slot, "_vitrine_mode", None) != mode:
            return GLib.SOURCE_REMOVE
        want = "list" if mode == "columns" else mode
        if native.view_mode(slot) not in (None, want):
            self.ext.suppress()
            native.set_view_mode(slot, want)
        return GLib.SOURCE_REMOVE

    def user_set_mode(self, mode: str, zoom: str | None = None) -> None:
        """Escolha explícita do usuário na pasta atual: aplica e (se ativado) lembra."""
        slot = self.active_slot()
        uri = native.slot_uri(slot)
        if slot is None:
            return
        if zoom is None and mode == "grid":
            rule, exact = self.cfg.rule_for(uri) if uri else (None, False)
            zoom = ((rule or {}).get("zoom") if exact else None) or self.ext.current_grid_zoom()
        self.apply_mode(slot, mode, zoom)
        if self.cfg.get("remember_per_folder") and native.is_regular_location(uri):
            self.cfg.set_rule(uri, mode=mode, zoom=zoom if mode == "grid" else None)

    def record_zoom(self, zoom: str) -> None:
        slot = self.active_slot()
        uri = native.slot_uri(slot)
        if (slot is None or getattr(slot, "_vitrine_mode", None) != "grid"
                or not native.is_regular_location(uri) or not self.cfg.get("remember_per_folder")):
            return
        self.cfg.set_rule(uri, mode="grid", zoom=zoom)

    def _detect_media(self, slot, uri: str) -> None:
        """Pasta com maioria de fotos/vídeos → ícones grandes (sem precisar configurar)."""
        if uri in self._media_cache:
            self._apply_detected(slot, uri, self._media_cache[uri])
            return
        gfile = Gio.File.new_for_uri(uri)

        def on_enum(f, res):
            try:
                en = f.enumerate_children_finish(res)
            except GLib.Error:
                self._apply_detected(slot, uri, False)
                return
            en.next_files_async(_MEDIA_SAMPLE, GLib.PRIORITY_DEFAULT, None, on_files)

        def on_files(en, res):
            try:
                infos = en.next_files_finish(res)
            except GLib.Error:
                infos = []
            en.close_async(GLib.PRIORITY_LOW, None, None)
            files = [i for i in infos if i.get_file_type() == Gio.FileType.REGULAR
                     and not i.get_is_hidden()]
            media = [i for i in files if (i.get_content_type() or "").startswith(("image/", "video/"))]
            ratio = (len(media) / len(files)) if files else 0.0
            is_media = len(media) >= 4 and ratio >= float(self.cfg.get("auto_media_ratio"))
            self._media_cache[uri] = is_media
            self._apply_detected(slot, uri, is_media)

        gfile.enumerate_children_async(
            "standard::type,standard::content-type,standard::is-hidden",
            Gio.FileQueryInfoFlags.NONE, GLib.PRIORITY_DEFAULT, None, on_enum)

    @guarded
    def _apply_detected(self, slot, uri: str, is_media: bool) -> None:
        if native.slot_uri(slot) != uri:
            return
        if is_media:
            debug(f"pasta de mídia detectada: {uri}")
            self.apply_mode(slot, "grid", self.cfg.get("auto_media_zoom"))
        else:
            self.apply_mode(slot, self.cfg.get("default_mode"))

    # ───────────────────────── colunas / painel ─────────────────────────
    def _set_columns_visible(self, on: bool) -> None:
        self.columns_on = on
        if self.strip is not None:
            if on:
                slot = self.active_slot()
                loc = native.slot_location(slot)
                ok = loc is not None and native.is_regular_location(loc.get_uri())
                self.strip.set_location(loc if ok else None)
            else:
                self.strip.set_visible(False)
        self._sync_buttons()

    def set_preview_visible(self, on: bool) -> None:
        self.preview.set_visible(on)
        self.cfg.set("preview_visible", on)
        self._sync_buttons()
        if on:
            self._pos_initialized = False
            self._on_paned_max()
            model = self.model_watch.get()
            self.preview.show_uris(native.selected_uris(model) if model is not None else [])

    def _sync_buttons(self) -> None:
        self._syncing_buttons = True
        try:
            if self.btn_columns is not None:
                self.btn_columns.set_active(self.columns_on)
            if self.btn_preview is not None and self.preview is not None:
                self.btn_preview.set_active(self.preview.get_visible())
        finally:
            self._syncing_buttons = False

    @guarded
    def _on_btn_columns(self, btn) -> None:
        if self._syncing_buttons:
            return
        if btn.get_active():
            self.user_set_mode("columns")
        else:
            self.user_set_mode("list")

    @guarded
    def _on_btn_preview(self, btn) -> None:
        if not self._syncing_buttons:
            self.set_preview_visible(btn.get_active())

    @guarded
    def _on_paned_max(self, *_a) -> None:
        if self._pos_initialized or self.paned is None or not self.preview.get_visible():
            return
        maxpos = self.paned.get_property("max-position")
        if maxpos <= 0:
            return
        width = int(self.cfg.get("preview_width"))
        self._setting_pos = True
        self.paned.set_position(max(200, maxpos - width))
        self._setting_pos = False
        self._pos_initialized = True

    @guarded
    def _on_paned_pos(self, *_a) -> None:
        if self._setting_pos or not self._pos_initialized or not self.preview.get_visible():
            return
        width = self.paned.get_property("max-position") - self.paned.get_position()
        if 180 <= width <= 1200 and width != self.cfg.get("preview_width"):
            self.cfg.set("preview_width", int(width))

    @guarded
    def _on_destroy(self, *_a) -> None:
        self.model_watch.unbind()
        if self.strip is not None:
            self.strip.teardown()
        self.ext.forget_window(self.win)
__VITRINE_ARQUIVO_10__
mkdir -p "tools"
cat > 'tools/smoke_test.py' <<'__VITRINE_ARQUIVO_11__'
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
__VITRINE_ARQUIVO_11__
mkdir -p "tools"
cat > 'tools/build_bootstrap.py' <<'__VITRINE_ARQUIVO_12__'
"""Gera `criar-vitrine.sh`: um único script bash que recria o projeto inteiro
(todos os arquivos) numa pasta e, se você quiser, já instala no Nautilus.

    python3 tools/build_bootstrap.py
"""

import os
import stat

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(ROOT, "criar-vitrine.sh")
INCLUDE = [
    "nautilus-vitrine.py",
    "vitrine",
    "tools/smoke_test.py",
    "tools/build_bootstrap.py",
    "install.sh",
    "uninstall.sh",
    ".vscode",
    "README.md",
    "LICENSE",
    ".gitignore",
    "Makefile",
    "packaging",
    ".copr",
]
EXECUTABLE = {"install.sh", "uninstall.sh"}

HEADER = r'''#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  criar-vitrine.sh — cria o projeto "Vitrine para Nautilus" (Fedora / GNOME)
#
#  Uso:
#     bash criar-vitrine.sh                 # cria em ~/nautilus-vitrine
#     bash criar-vitrine.sh ~/Projetos/vit  # cria na pasta indicada
#     bash criar-vitrine.sh --instalar      # cria e já instala no Nautilus
#
#  Depois:  code ~/nautilus-vitrine   (abre no VS Code; Ctrl+Shift+B instala)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TARGET="$HOME/nautilus-vitrine"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --instalar|--install) INSTALL=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) TARGET="$arg" ;;
  esac
done

if [[ -e "$TARGET" && -n "$(ls -A "$TARGET" 2>/dev/null)" ]]; then
  read -r -p "A pasta $TARGET já existe e não está vazia. Sobrescrever os arquivos da Vitrine? [s/N] " ans
  [[ "${ans:-N}" =~ ^[SsYy]$ ]] || { echo "Cancelado."; exit 1; }
fi
mkdir -p "$TARGET"
cd "$TARGET"
echo "Criando arquivos em $TARGET …"

'''

FOOTER = r'''
chmod +x install.sh uninstall.sh
echo "Projeto criado em $TARGET"

if [[ "$INSTALL" == 1 ]]; then
  ./install.sh
else
  echo
  echo "Próximos passos:"
  echo "  cd \"$TARGET\" && ./install.sh        # instala e reinicia o Nautilus"
  echo "  code \"$TARGET\"                      # abre no VS Code (Ctrl+Shift+B = instalar em modo dev)"
fi
'''


def collect() -> list[str]:
    files = []
    for entry in INCLUDE:
        path = os.path.join(ROOT, entry)
        if os.path.isdir(path):
            for dirpath, dirnames, filenames in os.walk(path):
                dirnames[:] = sorted(d for d in dirnames if d != "__pycache__")
                for name in sorted(filenames):
                    if name.endswith((".pyc", ".tmp")):
                        continue
                    files.append(os.path.relpath(os.path.join(dirpath, name), ROOT))
        elif os.path.exists(path):
            files.append(entry)
    return files


def main() -> None:
    parts = [HEADER]
    for i, rel in enumerate(collect()):
        with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
            content = fh.read()
        delim = f"__VITRINE_ARQUIVO_{i}__"
        assert delim not in content
        if not content.endswith("\n"):
            content += "\n"
        d = os.path.dirname(rel)
        if d:
            parts.append(f'mkdir -p "{d}"\n')
        parts.append(f"cat > '{rel}' <<'{delim}'\n{content}{delim}\n")
    parts.append(FOOTER)
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write("".join(parts))
    os.chmod(OUT, os.stat(OUT).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    print(f"gerado: {OUT}")


if __name__ == "__main__":
    main()
__VITRINE_ARQUIVO_12__
cat > 'install.sh' <<'__VITRINE_ARQUIVO_13__'
#!/usr/bin/env bash
# Instala a Vitrine para o seu usuário (não precisa de root, exceto para o nautilus-python).
#
#   ./install.sh          copia os arquivos
#   ./install.sh --dev    cria links simbólicos (edite no VS Code e só reinicie o Nautilus)
#   ./install.sh --no-restart
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/nautilus-python/extensions"
MODE="copy"
RESTART=1
for arg in "$@"; do
  case "$arg" in
    --dev) MODE="link" ;;
    --no-restart) RESTART=0 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
  esac
done

if ! rpm -q nautilus-python >/dev/null 2>&1; then
  echo "O pacote nautilus-python não está instalado; ele é necessário para carregar extensões em Python."
  read -r -p "Instalar agora com 'sudo dnf install nautilus-python'? [S/n] " ans
  if [[ "${ans:-S}" =~ ^[SsYy]$ ]]; then
    sudo dnf install -y nautilus-python
  else
    echo "Instale depois com: sudo dnf install nautilus-python"
    exit 1
  fi
fi

if rpm -q nautilus-vitrine >/dev/null 2>&1; then
  echo "Aviso: o pacote RPM nautilus-vitrine também está instalado."
  echo "Só uma cópia fica ativa (a primeira que o Nautilus carregar)."
  echo "Para testar esta cópia de desenvolvimento: sudo dnf remove nautilus-vitrine"
fi

mkdir -p "$DEST"
rm -rf "$DEST/vitrine" "$DEST/nautilus-vitrine.py"
if [[ "$MODE" == "link" ]]; then
  ln -s "$HERE/vitrine" "$DEST/vitrine"
  ln -s "$HERE/nautilus-vitrine.py" "$DEST/nautilus-vitrine.py"
  echo "Links de desenvolvimento criados em $DEST"
else
  cp -r "$HERE/vitrine" "$DEST/vitrine"
  cp "$HERE/nautilus-vitrine.py" "$DEST/nautilus-vitrine.py"
  find "$DEST/vitrine" -name '__pycache__' -prune -exec rm -rf {} +
  echo "Arquivos copiados para $DEST"
fi

if [[ "$RESTART" == 1 ]]; then
  echo "Reiniciando o Nautilus (janelas abertas do Arquivos serão fechadas)…"
  nautilus -q 2>/dev/null || true
  sleep 1
  (setsid nautilus >/dev/null 2>&1 &)
fi
echo "Pronto. Log: ${XDG_CACHE_HOME:-$HOME/.cache}/nautilus-vitrine/vitrine.log"
__VITRINE_ARQUIVO_13__
cat > 'uninstall.sh' <<'__VITRINE_ARQUIVO_14__'
#!/usr/bin/env bash
# Remove a Vitrine. Suas regras por pasta ficam em ~/.config/nautilus-vitrine
# (use --purge para apagá-las também).
set -euo pipefail
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/nautilus-python/extensions"
rm -rf "$DEST/vitrine" "$DEST/nautilus-vitrine.py"
if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/nautilus-vitrine" "${XDG_CACHE_HOME:-$HOME/.cache}/nautilus-vitrine"
fi
nautilus -q 2>/dev/null || true
echo "Vitrine removida. Abra o Arquivos de novo para voltar ao Nautilus original."
__VITRINE_ARQUIVO_14__
mkdir -p ".vscode"
cat > '.vscode/extensions.json' <<'__VITRINE_ARQUIVO_15__'
{
  "recommendations": ["ms-python.python", "ms-python.vscode-pylance"]
}
__VITRINE_ARQUIVO_15__
mkdir -p ".vscode"
cat > '.vscode/settings.json' <<'__VITRINE_ARQUIVO_16__'
{
  "python.defaultInterpreterPath": "/usr/bin/python3",
  "python.analysis.extraPaths": ["${workspaceFolder}"],
  "files.exclude": { "**/__pycache__": true },
  "editor.rulers": [100],
  "[python]": { "editor.tabSize": 4 }
}
__VITRINE_ARQUIVO_16__
mkdir -p ".vscode"
cat > '.vscode/tasks.json' <<'__VITRINE_ARQUIVO_17__'
{
  // Ctrl+Shift+P → "Tasks: Run Task" para ver estas tarefas.
  // Ctrl+Shift+B roda a tarefa padrão (instalar em modo dev + reiniciar o Nautilus).
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Vitrine: instalar (modo dev, com links) e reiniciar Nautilus",
      "type": "shell",
      "command": "./install.sh --dev",
      "group": { "kind": "build", "isDefault": true },
      "problemMatcher": []
    },
    {
      "label": "Vitrine: instalar (cópia definitiva)",
      "type": "shell",
      "command": "./install.sh",
      "problemMatcher": []
    },
    {
      "label": "Vitrine: reiniciar Nautilus",
      "type": "shell",
      "command": "nautilus -q; sleep 1; (setsid nautilus >/dev/null 2>&1 &)",
      "problemMatcher": []
    },
    {
      "label": "Vitrine: rodar Nautilus em modo depuração (log no terminal)",
      "type": "shell",
      "command": "nautilus -q; sleep 1; VITRINE_DEBUG=1 VITRINE_DUMP=1 nautilus",
      "isBackground": true,
      "problemMatcher": []
    },
    {
      "label": "Vitrine: autoteste dentro do Nautilus (resultado no log)",
      "type": "shell",
      "command": "rm -f ~/.cache/nautilus-vitrine/vitrine.log; nautilus -q; sleep 1; (VITRINE_SELFTEST=1 setsid nautilus --new-window \"$HOME\" >/dev/null 2>&1 &); timeout 60 bash -c 'until grep -q \"SELFTEST RESUMO\" ~/.cache/nautilus-vitrine/vitrine.log 2>/dev/null; do sleep 2; done'; grep SELFTEST ~/.cache/nautilus-vitrine/vitrine.log",
      "problemMatcher": []
    },
    {
      "label": "Vitrine: acompanhar log",
      "type": "shell",
      "command": "mkdir -p ~/.cache/nautilus-vitrine && touch ~/.cache/nautilus-vitrine/vitrine.log && tail -n 80 -f ~/.cache/nautilus-vitrine/vitrine.log",
      "isBackground": true,
      "problemMatcher": []
    },
    {
      "label": "Vitrine: teste fora do Nautilus (colunas + preview)",
      "type": "shell",
      "command": "python3 -u tools/smoke_test.py \"$(xdg-user-dir PICTURES)\"",
      "problemMatcher": []
    },
    {
      "label": "Vitrine: checar sintaxe",
      "type": "shell",
      "command": "python3 -m py_compile nautilus-vitrine.py vitrine/*.py tools/*.py && echo OK",
      "problemMatcher": []
    },
    {
      "label": "Vitrine: gerar script único criar-vitrine.sh",
      "type": "shell",
      "command": "python3 tools/build_bootstrap.py",
      "problemMatcher": []
    },
    {
      "label": "Vitrine: desinstalar",
      "type": "shell",
      "command": "./uninstall.sh",
      "problemMatcher": []
    }
  ]
}
__VITRINE_ARQUIVO_17__
cat > 'README.md' <<'__VITRINE_ARQUIVO_18__'
# Vitrine para Nautilus

**Modo Colunas, painel de pré-visualização e visualização por pasta para o Arquivos (Nautilus) do GNOME, inspirados no Finder do macOS, sem perder nenhuma função nativa.**

![Nautilus 51](https://img.shields.io/badge/Nautilus-51-4a86cf)
![Fedora 45](https://img.shields.io/badge/Fedora-45-51a2da)
![Python](https://img.shields.io/badge/Python-3-3776ab)
![Licença MIT](https://img.shields.io/badge/licen%C3%A7a-MIT-green)

<!-- Capturas de tela: salve as imagens em docs/ e descomente as linhas abaixo.
![Modo Colunas com pré-visualização](docs/colunas.png)
![Pasta Imagens em ícones grandes](docs/imagens.png)
-->

A Vitrine é uma extensão para o **Nautilus 51** (e, em princípio, o 50). Ela acrescenta ao gerenciador de arquivos do GNOME três recursos que fazem falta para quem vem do macOS:

- 🗂️ **Modo Colunas**: navegue pelas pastas em colunas, como no Finder.
- 🖼️ **Painel de pré-visualização**: veja imagens, textos, vídeos, PDFs e pastas ao lado da lista, sem abrir nada.
- 📌 **Visualização por pasta**: cada pasta lembra se você prefere lista, ícones, ícones grandes ou colunas.

A diferença em relação a outras soluções é o **modo híbrido**. A pasta atual continua sendo exibida pela **própria lista do Nautilus**, então menu de contexto, renomear, arrastar e soltar, recortar e colar, Desfazer, scripts e outras extensões funcionam exatamente como antes. A Vitrine só acrescenta coisas; não substitui nada.

---

## Recursos

### 🗂️ Modo Colunas

- Ative com **Ctrl+3** ou com o botão de colunas na barra superior.
- As pastas anteriores do caminho aparecem como colunas à esquerda, com o item do caminho destacado. A pasta atual fica na lista nativa do Nautilus, à direita.
- Clique numa pasta de qualquer coluna para ir até ela. Navegar com as setas do teclado funciona.
- Clique num arquivo de uma coluna anterior para abrir a pasta dele **já com o arquivo selecionado** na lista nativa, com todas as ações do Nautilus disponíveis.
- **Arraste e solte** entre colunas, da coluna para a lista e da lista para a coluna. Mover e copiar usam as operações do próprio Nautilus, com barra de progresso, diálogo de conflito e **Ctrl+Z**.
- Clique do meio numa pasta abre em nova janela. O clique direito traz Abrir, Abrir em nova janela, Mostrar na lista, Copiar caminho e Mover para a lixeira.
- Respeita a opção de **mostrar arquivos ocultos** do Nautilus.

### 🖼️ Painel de pré-visualização

Ative com **Ctrl+Shift+P** ou com o botão de painel. A largura pode ser ajustada arrastando a borda e fica salva.

| Seleção | O que o painel mostra |
|---|---|
| Imagem | A imagem com rotação EXIF correta, dimensões, tipo, tamanho e datas |
| Texto / código | O conteúdo, em fonte monoespaçada (até 400 linhas) |
| Vídeo, PDF, documentos | A miniatura do sistema (gerada na hora, se ainda não existir) |
| Pasta | A lista do conteúdo, com contagem de pastas e arquivos. Clique para entrar |
| Vários itens | A quantidade de itens e o tamanho total |
| Nada selecionado | As informações da pasta atual |

O botão **Abrir** usa o aplicativo padrão. O botão 👁 (ou a tecla **Espaço**) abre a visualização rápida do GNOME (Sushi).

**Rápido de verdade.** No Fedora 45 o carregador de imagens do sistema (glycin) abre um processo isolado para cada imagem. A Vitrine contorna isso:

- mostra a miniatura já existente na hora;
- decodifica JPEG, PNG e TIFF com o decodificador do GTK, lendo dimensões e rotação direto do cabeçalho;
- guarda em cache as imagens já vistas;
- pré-carrega as imagens vizinhas.

| Situação (medida no Nautilus 51) | Primeira imagem | Imagem nítida |
|---|---|---|
| Foto nova | ~40 ms | ~190 ms |
| Foto vizinha (pré-carregada) | ~38 ms | ~38 ms |
| Foto já vista | ~37 ms | ~37 ms |

### 📌 Visualização por pasta

- Trocou de visualização numa pasta, com **Ctrl+1** (lista), **Ctrl+2** (ícones), **Ctrl+3** (colunas), os botões ou o menu? A Vitrine **lembra a escolha para aquela pasta**. Pastas sem regra usam o seu padrão.
- O **zoom dos ícones também é salvo por pasta**: ícones gigantes em *Imagens*, ícones normais em *Downloads*.
- **Pastas de fotos e vídeos são detectadas automaticamente.** Se a maioria dos arquivos for imagem ou vídeo, a pasta abre em ícones grandes.
- Na primeira execução, *Imagens* e *Vídeos* já vêm configuradas para ícones grandes, **incluindo as subpastas**.
- Navegando em colunas, as subpastas continuam em colunas.

Clique com o botão direito no **fundo de qualquer pasta** e escolha **Visualização desta pasta**:

- Lista · Ícones · Ícones grandes · Colunas
- Aplicar também às subpastas / Não aplicar às subpastas
- Esquecer esta pasta (usar o padrão)
- Usar a visualização atual como padrão
- Mostrar/ocultar pré-visualização

---

## Instalação

### Requisitos

- **Nautilus 51** (GNOME 51, Fedora 45), versão em que a extensão foi testada. O Nautilus 50 (Fedora 44) tem a mesma estrutura de janela e deve funcionar, mas ainda não foi testado. Outras distribuições com essas versões também devem funcionar.
- `nautilus-python` (o instalador oferece instalar).

### Opção 1 (recomendada): clonar o repositório

```bash
git clone https://github.com/viniciusbispo19/nautilus-vitrine.git
```

```bash
cd nautilus-vitrine && ./install.sh
```

O `install.sh` instala o `nautilus-python` se faltar (pede sua senha), copia a extensão para `~/.local/share/nautilus-python/extensions/` e reinicia o Nautilus. Para atualizar depois: `git pull && ./install.sh`.

### Opção 2: script único

O arquivo `criar-vitrine.sh` contém o projeto inteiro. Baixe-o e rode:

```bash
bash criar-vitrine.sh --instalar
```

Ele cria a pasta `~/nautilus-vitrine` com todos os arquivos e já instala. Sem `--instalar`, só cria a pasta. Também dá para passar outro destino: `bash criar-vitrine.sh ~/Projetos/vitrine`.

### Em breve: pacote RPM pelo COPR

O pacote RPM já está pronto (`packaging/nautilus-vitrine.spec`), mas **ainda não foi publicado no COPR**. Quando estiver disponível, a instalação será:

```
sudo dnf copr enable viniciusbispo19/nautilus-vitrine
sudo dnf install nautilus-vitrine
```

Até lá, use a opção 1 ou 2, ou gere o RPM localmente (veja *Empacotamento*).

### Desinstalar

```bash
./uninstall.sh
```

O Nautilus volta exatamente ao original. Suas regras ficam guardadas; use `./uninstall.sh --purge` para apagar tudo.

> **Não é uma extensão do GNOME Shell.** A Vitrine roda dentro do Nautilus, via nautilus-python, e por isso não aparece no app Extensões nem no extensions.gnome.org. Ela é gerenciada pelos scripts acima.

---

## Atalhos

| Atalho | Ação |
|---|---|
| **Ctrl+3** | Modo Colunas |
| **Ctrl+1** / **Ctrl+2** | Lista / Ícones (nativos do Nautilus, agora lembrados por pasta) |
| **Ctrl+Shift+P** | Mostrar/ocultar a pré-visualização |
| **Espaço** | Visualização rápida (Sushi) |
| **Ctrl + roda do mouse** | Zoom (salvo por pasta na visualização em ícones) |
| Clique do meio numa coluna | Abrir a pasta em nova janela |

---

## Configuração

Tudo funciona sem configurar nada. Para ajustes finos, edite os arquivos abaixo com o Nautilus fechado (`nautilus -q`).

**`~/.config/nautilus-vitrine/settings.json`**

| Chave | Padrão | Descrição |
|---|---|---|
| `preview_visible` | `true` | Painel de pré-visualização aberto |
| `preview_width` | `320` | Largura do painel (px), salva ao arrastar a borda |
| `column_width` | `230` | Largura de cada coluna (px) |
| `max_visible_columns` | `3` | Colunas visíveis antes de começar a rolar |
| `remember_per_folder` | `true` | Lembrar a visualização escolhida em cada pasta |
| `auto_media_grid` | `true` | Abrir pastas de fotos/vídeos em ícones grandes |
| `auto_media_zoom` | `"extra-large"` | Zoom usado nessas pastas |
| `auto_media_ratio` | `0.6` | Proporção mínima de mídia para considerar "pasta de fotos" |
| `default_mode` | do Nautilus | Visualização das pastas sem regra: `list`, `grid` ou `columns` |
| `default_grid_zoom` | do Nautilus | Zoom padrão dos ícones |

**`~/.config/nautilus-vitrine/folders.json`** guarda as regras por pasta:

```json
{
  "file:///home/voce/Imagens": { "mode": "grid", "zoom": "extra-large", "recursive": true },
  "file:///home/voce/Projetos": { "mode": "columns" }
}
```

Zooms válidos: `small`, `small-plus`, `medium`, `large`, `extra-large`.

---

## Como funciona

O Nautilus não tem API pública para novas visualizações ou painéis. Assim como o [My Computer for Nautilus](https://github.com/yannmasoch/nautilus-my-computer), a Vitrine roda dentro do processo do Nautilus (via nautilus-python) e insere seus widgets na janela em tempo de execução. Para quebrar o mínimo possível com atualizações do GNOME:

- **Um único ponto de injeção.** Só o conteúdo do `AdwToolbarView` que contém as abas é envolvido por `[colunas | abas do Nautilus] ‖ [pré-visualização]`. O resto da janela fica intocado.
- **Nada do Nautilus é reimplementado.** A pasta atual é sempre a lista nativa, e a seleção é lida do próprio `NautilusViewModel`.
- **Sem referências fortes.** Widgets e modelos do Nautilus nunca são mantidos vivos pela extensão; o modelo de seleção é acompanhado por *weak reference*.
- **Operações nativas.** Mover, copiar e lixeira passam pela API D-Bus `org.gnome.Nautilus.FileOperations2`, com progresso, conflitos e Desfazer.
- **Falha segura.** Se uma versão futura do Nautilus mudar a estrutura da janela, a Vitrine simplesmente não se injeta e registra o motivo no log. Exceções em callbacks também viram log, sem derrubar o Nautilus.

### Estrutura do código

```
nautilus-vitrine.py     ponto de entrada carregado pelo nautilus-python
vitrine/
  main.py               descobre as janelas, CSS, menu "Visualização desta pasta"
  window.py             injeção por janela, botões, atalhos, regras por pasta
  columns.py            Modo Colunas (Gtk.DirectoryList + ListView)
  preview.py            painel de pré-visualização
  imageload.py          carregamento rápido de imagens, cache e pré-carregamento
  native.py             ponte com o Nautilus (slot, lista/grade, seleção)
  config.py             preferências e regras (JSON)
  util.py               log, varredura de widgets, operações D-Bus
  selftest.py           autoteste dentro do Nautilus real
tools/
  smoke_test.py         teste das colunas e do preview fora do Nautilus
  build_bootstrap.py    gera o criar-vitrine.sh
packaging/
  nautilus-vitrine.spec receita do pacote RPM
.copr/Makefile          build automático no COPR
```

---

## Desenvolvimento

```bash
./install.sh --dev
```

O modo dev usa links simbólicos: edite o código e só reinicie o Nautilus (`nautilus -q`).

O projeto inclui tarefas do **VS Code** (*Terminal → Run Task*):

| Tarefa | O que faz |
|---|---|
| **Ctrl+Shift+B** | Instala em modo dev e reinicia o Nautilus |
| Autoteste dentro do Nautilus | 19 verificações automáticas: injeção, colunas, preview, regras por pasta, zoom e tempo de carregamento das imagens. Suas regras e o zoom são restaurados no fim |
| Rodar em modo depuração | `VITRINE_DEBUG=1 VITRINE_DUMP=1 nautilus` (inclui a árvore de widgets da janela no log) |
| Acompanhar log | `tail -f ~/.cache/nautilus-vitrine/vitrine.log` |
| Teste fora do Nautilus | Abre colunas e preview numa janela própria |
| Gerar script único | Atualiza o `criar-vitrine.sh` |

Para rodar o autoteste pelo terminal:

```bash
nautilus -q; VITRINE_SELFTEST=1 nautilus --new-window ~ &
```

Depois de alguns segundos, veja o resultado:

```bash
grep SELFTEST ~/.cache/nautilus-vitrine/vitrine.log
```

### Empacotamento (RPM / COPR)

```bash
sudo dnf install make rpm-build python3-devel
```

```bash
make rpm
```

O RPM sai em `dist/`; `make install-rpm` instala. A receita fica em `packaging/nautilus-vitrine.spec`.

O COPR gera o pacote direto deste repositório usando `.copr/Makefile`. Configuração única em [copr.fedorainfracloud.org](https://copr.fedorainfracloud.org):

1. Entre com a conta Fedora e crie o projeto `nautilus-vitrine`, marcando os *chroots* `fedora-45-x86_64` e `fedora-44-x86_64` (e outros que quiser).
2. Em **Packages → New package → SCM**: *Clone URL* `https://github.com/viniciusbispo19/nautilus-vitrine`, *Spec file* `packaging/nautilus-vitrine.spec`, *SRPM build method* **make srpm**.
3. Clique em **Rebuild**. Para gerar automaticamente a cada `git push`, ative o *webhook* do GitHub em **Settings → Integrations** do projeto COPR.

Para lançar uma versão nova: aumente `Version` e acrescente uma entrada no `%changelog` do `.spec` (e o `VERSION` em `vitrine/main.py`), faça o commit e o push.

---

## Solução de problemas

- **Nada mudou no Nautilus:** confira se o `nautilus-python` está instalado (`rpm -q nautilus-python`), feche o Nautilus por completo (`nautilus -q`) e abra de novo.
- **Algo estranho aconteceu:** veja `~/.cache/nautilus-vitrine/vitrine.log`. A linha `janela injetada com sucesso` confirma que a extensão carregou. Se o log apontar que o TabView não foi encontrado, a estrutura do Nautilus mudou: abra uma *issue* com o log.
- **Quer voltar ao Nautilus original:** `./uninstall.sh`.

## Limitações conhecidas

- A extensão usa estruturas internas do Nautilus, que podem mudar a cada versão do GNOME. Foi testada no Nautilus 51.1 (Fedora 45).
- Nas colunas anteriores o menu de clique direito é reduzido. Para o menu completo, use **Mostrar na lista**.
- O zoom dos ícones é uma preferência global do Nautilus. Ao entrar numa pasta com zoom salvo, outras janelas abertas em ícones acompanham.
- Locais especiais (Recentes, Favoritos, Lixeira, Rede, Pesquisa) mantêm o comportamento padrão do Nautilus.

## Próximos passos

- [x] Pacote RPM (`make rpm`)
- [ ] Publicação no COPR (`dnf copr enable`)
- [ ] Tocar vídeo e áudio direto no painel
- [ ] Folhear páginas de PDF no painel
- [ ] Dados EXIF da foto (câmera, lente, GPS)
- [ ] Tela de preferências

Sugestões e *pull requests* são bem-vindos.

## Créditos

A técnica de injeção na janela foi inspirada no projeto **[My Computer for Nautilus](https://github.com/yannmasoch/nautilus-my-computer)**, de Yann Masoch (licença MIT).

## Licença

[MIT](LICENSE)
__VITRINE_ARQUIVO_18__
cat > 'LICENSE' <<'__VITRINE_ARQUIVO_19__'
MIT License

Copyright (c) 2026 Vitrine para Nautilus contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---
Inspired by "My Computer for Nautilus" (https://github.com/yannmasoch/nautilus-my-computer),
Copyright (c) 2026 Yann Masoch, MIT License.
__VITRINE_ARQUIVO_19__
cat > '.gitignore' <<'__VITRINE_ARQUIVO_20__'
__pycache__/
*.pyc
*.tmp
dist/
dist-build.log
__VITRINE_ARQUIVO_20__
cat > 'Makefile' <<'__VITRINE_ARQUIVO_21__'
# Empacotamento local.  Requer: sudo dnf install make rpm-build python3-devel
#
#   make rpm        gera o RPM em dist/
#   make srpm       gera só o SRPM (o mesmo que o COPR usa)
#   make install-rpm  instala o RPM gerado (pede senha)
#   make clean

SPEC    := packaging/nautilus-vitrine.spec
VERSION := $(shell awk '/^Version:/ {print $$2}' $(SPEC))
DIST    := $(CURDIR)/dist
TARBALL := $(DIST)/nautilus-vitrine-$(VERSION).tar.gz
RPMDEFS := --define "_sourcedir $(DIST)" --define "_srcrpmdir $(DIST)" \
           --define "_rpmdir $(DIST)" --define "_builddir $(DIST)/build" \
           --define "_buildrootdir $(DIST)/buildroot"

.PHONY: tarball srpm rpm install-rpm clean

tarball:
	mkdir -p $(DIST)
	git archive --format=tar.gz --prefix=nautilus-vitrine-$(VERSION)/ -o $(TARBALL) HEAD

srpm: tarball
	rpmbuild -bs $(SPEC) $(RPMDEFS)

rpm: tarball
	rpmbuild -bb $(SPEC) $(RPMDEFS)
	@find $(DIST) -name '*.noarch.rpm' -printf 'RPM: %p\n'

install-rpm:
	sudo dnf install -y $$(find $(DIST) -name 'nautilus-vitrine-$(VERSION)-*.noarch.rpm' | head -1)

clean:
	rm -rf $(DIST)
__VITRINE_ARQUIVO_21__
mkdir -p "packaging"
cat > 'packaging/nautilus-vitrine.spec' <<'__VITRINE_ARQUIVO_22__'
%global extdir %{_datadir}/nautilus-python/extensions

Name:           nautilus-vitrine
Version:        0.1.0
Release:        1%{?dist}
Summary:        Column view, preview pane and per-folder views for GNOME Files (Nautilus)

License:        MIT
URL:            https://github.com/viniciusbispo19/nautilus-vitrine
Source0:        %{url}/archive/v%{version}/%{name}-%{version}.tar.gz

BuildArch:      noarch
BuildRequires:  python3-devel

Requires:       nautilus >= 50
Requires:       nautilus-python >= 4
Requires:       python3-gobject
Requires:       gtk4
Requires:       libadwaita
Recommends:     gnome-desktop4
Recommends:     sushi

%description
Vitrine adds three Finder-inspired features to GNOME Files (Nautilus 50/51):

 * Column view: parent folders are shown as columns on the left while the
   current folder stays in Nautilus' own list view, so context menus, rename,
   drag and drop, undo, scripts and other extensions keep working.
 * Preview pane: images (fast loading with cache and prefetch), text, video
   and PDF thumbnails, folder contents and file details next to the list.
 * Per-folder views: each folder remembers list, icons, large icons or
   columns, including the icon zoom; photo folders open in large icons.

%prep
%autosetup -n %{name}-%{version}

%build
# Python puro: nada para compilar.

%install
install -d %{buildroot}%{extdir}/vitrine
install -p -m 0644 nautilus-vitrine.py %{buildroot}%{extdir}/
install -p -m 0644 vitrine/*.py %{buildroot}%{extdir}/vitrine/
%py_byte_compile %{python3} %{buildroot}%{extdir}/vitrine

%files
%license LICENSE
%doc README.md
%{extdir}/nautilus-vitrine.py
%{extdir}/vitrine/

%changelog
* Wed Nov 11 2026 Vinicius Bispo - 0.1.0-1
- Primeira versão: modo Colunas, painel de pré-visualização e visualização por pasta
__VITRINE_ARQUIVO_22__
mkdir -p ".copr"
cat > '.copr/Makefile' <<'__VITRINE_ARQUIVO_23__'
# Usado pelo COPR (método "make srpm"): gera o SRPM direto do repositório git.
# O COPR chama:  make -f .copr/Makefile srpm outdir=<pasta> spec=<arquivo .spec>
SPEC := packaging/nautilus-vitrine.spec

srpm:
	dnf -y install git rpm-build
	git config --global --add safe.directory '*'
	$(eval VERSION := $(shell awk '/^Version:/ {print $$2}' $(SPEC)))
	mkdir -p $(outdir)
	git archive --format=tar.gz --prefix=nautilus-vitrine-$(VERSION)/ \
		-o $(outdir)/nautilus-vitrine-$(VERSION).tar.gz HEAD
	rpmbuild -bs $(SPEC) \
		--define "_sourcedir $(outdir)" \
		--define "_srcrpmdir $(outdir)"
__VITRINE_ARQUIVO_23__

chmod +x install.sh uninstall.sh
echo "Projeto criado em $TARGET"

if [[ "$INSTALL" == 1 ]]; then
  ./install.sh
else
  echo
  echo "Próximos passos:"
  echo "  cd \"$TARGET\" && ./install.sh        # instala e reinicia o Nautilus"
  echo "  code \"$TARGET\"                      # abre no VS Code (Ctrl+Shift+B = instalar em modo dev)"
fi
