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
