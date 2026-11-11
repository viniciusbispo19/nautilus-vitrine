"""Controlador por janela: injeta Colunas + Pré-visualização e aplica as regras por pasta."""

from __future__ import annotations

import os

from gi.repository import Adw, Gdk, Gio, GLib, Gtk

from . import native
from .columns import ColumnStrip
from .computer import ComputerPage
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
        self.computer: ComputerPage | None = None
        self.content_stack: Gtk.Stack | None = None
        self.sidebar_list: Gtk.ListBox | None = None
        self._computer_visible = False
        self.toasts_shown = 0

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

        self.computer = ComputerPage(self, self.ext.hub)

        # [colunas | (abas do Nautilus ou Meu computador)]  ‖  [pré-visualização]
        inner = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        toolbar.set_content(None)  # `tv` continua vivo: a referência Python o segura
        tv.set_hexpand(True)
        self.content_stack = Gtk.Stack(hexpand=True, hhomogeneous=False, vhomogeneous=False)
        self.content_stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        self.content_stack.set_transition_duration(120)
        self.content_stack.add_named(tv, "tabs")
        self.content_stack.add_named(self.computer, "computer")
        self.content_stack.set_visible_child_name("tabs")
        inner.append(self.strip)
        inner.append(self.content_stack)

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
        self._inject_sidebar_row()
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
        if self.cfg.get("start_on_computer"):
            self.show_computer(True)
        return GLib.SOURCE_REMOVE

    def _inject_sidebar_row(self) -> None:
        """Entrada "Meu computador" no topo da barra lateral.

        Usa a API pública AdwToolbarView.add_top_bar da própria barra lateral: nenhum
        widget do Nautilus é movido; a lista nativa de locais continua intocada."""
        sidebar = find_by_type_name(self.win, "NautilusSidebar")
        tbv = ancestor(sidebar, lambda w: isinstance(w, Adw.ToolbarView)) if sidebar else None
        if tbv is None or tbv.get_content() is not sidebar:
            log("inject: barra lateral com estrutura inesperada; sem a entrada Meu computador")
            return
        lb = Gtk.ListBox()
        lb.add_css_class("navigation-sidebar")
        lb.add_css_class("vitrine-sidebar")
        lb.set_selection_mode(Gtk.SelectionMode.SINGLE)
        row = Gtk.ListBoxRow()
        row.set_tooltip_text("Meu computador (Ctrl+Shift+C)")
        box = Gtk.Box(spacing=12)
        box.append(Gtk.Image.new_from_icon_name("computer-symbolic"))
        box.append(Gtk.Label(label="Meu computador", xalign=0, hexpand=True))
        row.set_child(box)
        lb.append(row)
        lb.connect("row-activated", lambda *_a: self.show_computer(True))
        tbv.add_top_bar(lb)
        self.sidebar_list = lb

        # Clicar em qualquer local nativo da barra lateral sai do Meu computador,
        # mesmo que seja a pasta onde a aba já está (aí o Nautilus não navega).
        click = Gtk.GestureClick.new()
        click.set_button(Gdk.BUTTON_PRIMARY)
        click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        click.connect("released", lambda *_a: GLib.idle_add(self._leave_computer_if_visible))
        sidebar.add_controller(click)

    def _leave_computer_if_visible(self) -> bool:
        if self._computer_visible:
            self.show_computer(False)
        return GLib.SOURCE_REMOVE

    # ───────────────────────── Meu computador ─────────────────────────
    def show_computer(self, on: bool = True) -> None:
        if self.content_stack is None or self.computer is None:
            return
        self._computer_visible = on
        self.content_stack.set_visible_child_name("computer" if on else "tabs")
        if on:
            if self.strip is not None:
                self.strip.set_visible(False)
            if self.preview is not None:
                self.preview.set_folder(None)
                self.preview.show_uris([])
            if self.sidebar_list is not None:
                self.sidebar_list.select_row(self.sidebar_list.get_row_at_index(0))
            sidebar = find_by_type_name(self.win, "NautilusSidebar")
            native_lb = find_first(sidebar, lambda w: isinstance(w, Gtk.ListBox)) if sidebar else None
            if native_lb is not None:
                native_lb.unselect_all()
            self.computer.grab_focus()
        else:
            if self.sidebar_list is not None:
                self.sidebar_list.unselect_all()
            slot = self.active_slot()
            if slot is not None:
                self._set_columns_visible(getattr(slot, "_vitrine_mode", None) == "columns")
                self._sync_active_ui(slot)

    def computer_visible(self) -> bool:
        return self._computer_visible

    def leave_computer_and_open(self, uri: str) -> None:
        self.show_computer(False)
        self.navigate(uri)

    def preview_location(self, uri: str | None) -> None:
        if self.preview is not None and self.preview.get_visible() and uri:
            self.preview.show_uris([uri])

    def toast(self, text: str, button_label: str | None = None, on_button=None,
              timeout: int = 5) -> None:
        overlay = find_first(self.win, lambda w: isinstance(w, Adw.ToastOverlay))
        if overlay is None:
            log(f"aviso (sem área de avisos): {text}")
            return
        t = Adw.Toast(title=GLib.markup_escape_text(text))
        t.set_timeout(timeout)
        if button_label and on_button is not None:
            t.set_button_label(button_label)
            t.connect("button-clicked", lambda *_a: on_button())
        overlay.add_toast(t)
        self.toasts_shown += 1

    def on_new_device(self, key: str, name: str, mount, volume) -> None:
        """Pen drive, HD externo, cartão… acabou de ser conectado."""

        def open_device():
            m = mount or (volume.get_mount() if volume is not None else None)
            if m is not None:
                self.leave_computer_and_open(m.get_default_location().get_uri())
            elif volume is not None:
                self.computer.mount_and_open(volume, key)

        self.toast(f"{name} conectado", "Abrir", open_device, timeout=10)
        if self.computer is not None:
            self.computer.mark_new(key)

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
            if keyval in (Gdk.KEY_1, Gdk.KEY_2, Gdk.KEY_3) and self._computer_visible:
                self.show_computer(False)
            if keyval == Gdk.KEY_3:
                self.user_set_mode("columns")
                return True
            if keyval in (Gdk.KEY_1, Gdk.KEY_2):
                # O Nautilus troca lista/grade sozinho; nós só registramos e saímos das colunas.
                mode = "list" if keyval == Gdk.KEY_1 else "grid"
                GLib.idle_add(self._after_native_key, mode)
                return False
        if mods == (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK):
            if keyval in (Gdk.KEY_P, Gdk.KEY_p):
                self.set_preview_visible(not self.preview.get_visible())
                return True
            if keyval in (Gdk.KEY_C, Gdk.KEY_c):
                self.show_computer(not self._computer_visible)
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
        if self._computer_visible:
            self.show_computer(False)
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
            if self._computer_visible:
                self.show_computer(False)  # navegou (barra de caminho, voltar, busca…)
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
        if self.preview is None or not self.preview.get_visible() or self._computer_visible:
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
            if self._computer_visible:
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
