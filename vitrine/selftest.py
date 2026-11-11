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
