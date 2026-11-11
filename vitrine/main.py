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
