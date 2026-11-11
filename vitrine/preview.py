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
