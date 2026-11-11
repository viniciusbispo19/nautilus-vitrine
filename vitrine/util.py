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
