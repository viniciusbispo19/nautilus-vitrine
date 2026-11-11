"""Página "Meu computador": pastas, discos e dispositivos (com uso de espaço) e
aviso quando um pen drive, HD externo, cartão ou celular é conectado."""

from __future__ import annotations

import os
import socket
import time

from gi.repository import Adw, Gdk, Gio, GLib, Gtk, Pango

from . import util
from .util import guarded, log

FS_ATTRS = "filesystem::size,filesystem::free,filesystem::type,filesystem::readonly"
USAGE_REFRESH_S = 10
ANNOUNCE_DEDUP_S = 15

FOLDERS = (
    (None, "user-home", "Pasta pessoal"),
    (GLib.UserDirectory.DIRECTORY_DESKTOP, "user-desktop", None),
    (GLib.UserDirectory.DIRECTORY_DOCUMENTS, "folder-documents", None),
    (GLib.UserDirectory.DIRECTORY_DOWNLOAD, "folder-download", None),
    (GLib.UserDirectory.DIRECTORY_MUSIC, "folder-music", None),
    (GLib.UserDirectory.DIRECTORY_PICTURES, "folder-pictures", None),
    (GLib.UserDirectory.DIRECTORY_VIDEOS, "folder-videos", None),
)


def _os_name() -> str:
    try:
        with open("/etc/os-release", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return "Linux"


class Device:
    """Uma entrada da seção de dispositivos (já montada ou não)."""

    __slots__ = ("key", "name", "gicon", "uri", "kind", "mount", "volume", "removable")

    def __init__(self, key, name, gicon, uri, kind, mount=None, volume=None, removable=False):
        self.key, self.name, self.gicon, self.uri = key, name, gicon, uri
        self.kind, self.mount, self.volume, self.removable = kind, mount, volume, removable

    @property
    def mounted(self) -> bool:
        return self.uri is not None

    def can_eject(self) -> bool:
        m = self.mount
        return m is not None and (m.can_eject() or m.can_unmount())


def _volume_key(volume: Gio.Volume) -> str:
    for kind in (Gio.VOLUME_IDENTIFIER_KIND_UUID, Gio.VOLUME_IDENTIFIER_KIND_UNIX_DEVICE):
        ident = volume.get_identifier(kind)
        if ident:
            return f"vol:{ident}"
    return f"vol:{volume.get_name()}"


def _is_removable(mount: Gio.Mount | None, volume: Gio.Volume | None) -> bool:
    drive = (volume.get_drive() if volume is not None else None) or (
        mount.get_drive() if mount is not None else None)
    if drive is not None:
        try:
            if drive.is_removable() or drive.is_media_removable():
                return True
        except AttributeError:
            pass
    return bool(mount is not None and mount.can_eject())


class DeviceHub:
    """Observa o Gio.VolumeMonitor uma vez por processo e avisa os ouvintes."""

    def __init__(self) -> None:
        self.vm = Gio.VolumeMonitor.get()
        self._listeners: list = []
        self._new_listeners: list = []
        self._pending = 0
        self._announced: dict[str, float] = {}
        self.own_mounts: set[str] = set()  # montagens que nós mesmos pedimos
        for sig in ("mount-changed", "mount-removed", "volume-changed", "volume-removed",
                    "drive-connected", "drive-disconnected", "drive-changed"):
            self.vm.connect(sig, lambda *_a: self._changed())
        self.vm.connect("volume-added", self._on_volume_added)
        self.vm.connect("mount-added", self._on_mount_added)

    def on_changed(self, cb) -> None:
        self._listeners.append(cb)

    def on_new_device(self, cb) -> None:
        self._new_listeners.append(cb)

    def _changed(self) -> None:
        if self._pending:
            return
        self._pending = GLib.timeout_add(150, self._emit)

    def _emit(self) -> bool:
        self._pending = 0
        for cb in list(self._listeners):
            try:
                cb()
            except Exception as err:  # noqa: BLE001
                log(f"DeviceHub ouvinte: {err}")
        return GLib.SOURCE_REMOVE

    # ── novos dispositivos ──
    @guarded
    def _on_volume_added(self, _vm, volume: Gio.Volume) -> None:
        self._changed()
        if _is_removable(None, volume):
            self.announce(_volume_key(volume), volume.get_name(), volume=volume)

    @guarded
    def _on_mount_added(self, _vm, mount: Gio.Mount) -> None:
        self._changed()
        volume = mount.get_volume()
        key = _volume_key(volume) if volume is not None else f"mnt:{mount.get_root().get_uri()}"
        if key in self.own_mounts:
            self.own_mounts.discard(key)
            return
        if mount.is_shadowed() or not _is_removable(mount, volume):
            return
        self.announce(key, mount.get_name(), mount=mount, volume=volume)

    def announce(self, key: str, name: str, *, mount=None, volume=None) -> None:
        now = time.monotonic()
        last = self._announced.get(key, 0)
        self._announced[key] = now
        if now - last < ANNOUNCE_DEDUP_S:
            return  # mesmo dispositivo (ex.: volume-added seguido de mount-added)
        log(f"novo dispositivo: {name} ({key})")
        for cb in list(self._new_listeners):
            try:
                cb(key, name, mount, volume)
            except Exception as err:  # noqa: BLE001
                log(f"DeviceHub novo dispositivo: {err}")

    # ── lista atual ──
    def devices(self) -> list[Device]:
        out = [Device("system:/", "Disco do sistema", Gio.ThemedIcon.new("drive-harddisk"),
                      "file:///", "system")]
        seen_volumes = set()
        for mount in self.vm.get_mounts():
            if mount.is_shadowed():
                continue
            volume = mount.get_volume()
            root = mount.get_root()
            uri = root.get_uri()
            scheme = GLib.Uri.peek_scheme(uri) or ""
            if volume is not None:
                seen_volumes.add(_volume_key(volume))
            removable = _is_removable(mount, volume)
            kind = "network" if scheme not in ("file", "") else ("removable" if removable else "internal")
            key = _volume_key(volume) if volume is not None else f"mnt:{uri}"
            out.append(Device(key, mount.get_name(), mount.get_icon(), uri, kind, mount, volume,
                              removable))
        for volume in self.vm.get_volumes():
            key = _volume_key(volume)
            if volume.get_mount() is not None or key in seen_volumes or not volume.can_mount():
                continue
            removable = _is_removable(None, volume)
            out.append(Device(key, volume.get_name(), volume.get_icon(), None,
                              "removable" if removable else "internal", None, volume, removable))
        return out


class ComputerPage(Gtk.ScrolledWindow):
    __gtype_name__ = "VitrineComputerPage"

    def __init__(self, ctl, hub: DeviceHub) -> None:
        super().__init__()
        self.ctl = ctl
        self.hub = hub
        self.add_css_class("vitrine-computer")
        self.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self._cards: dict[str, Gtk.FlowBoxChild] = {}
        self._new_keys: dict[str, float] = {}
        self._usage_source = 0
        self._dirty = True
        self._cancel = Gio.Cancellable()
        self._nautilus_prefs = Gio.Settings.new("org.gnome.nautilus.preferences")

        clamp = Adw.Clamp(maximum_size=1100, tightening_threshold=700)
        self.set_child(clamp)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        body.set_margin_top(24)
        body.set_margin_bottom(24)
        body.set_margin_start(18)
        body.set_margin_end(18)
        clamp.set_child(body)

        title = Gtk.Label(label="Meu computador", xalign=0)
        title.add_css_class("title-1")
        subtitle = Gtk.Label(label=f"{socket.gethostname()} · {_os_name()}", xalign=0)
        subtitle.add_css_class("dim-label")
        head = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        head.append(title)
        head.append(subtitle)
        body.append(head)

        self.folders_box = self._flowbox(max_per_line=8)
        body.append(self._section("Pastas", self.folders_box))
        self.devices_box = self._flowbox(max_per_line=4)
        body.append(self._section("Dispositivos e unidades", self.devices_box))
        self.network_box = self._flowbox(max_per_line=4)
        self.network_section = self._section("Rede", self.network_box)
        body.append(self.network_section)

        if GLib.find_program_in_path("gnome-disks"):
            disks = Gtk.Button(label="Abrir Discos (formatar, partições…)", halign=Gtk.Align.START)
            disks.add_css_class("flat")
            disks.connect("clicked", lambda *_: self._launch("gnome-disks"))
            body.append(disks)

        hub.on_changed(self._on_hub_changed)
        self.connect("map", lambda *_: self._on_map())
        self.connect("unmap", lambda *_: self._stop_usage_poll())

    # ── montagem da página ──
    def _section(self, title: str, child: Gtk.Widget) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        lbl = Gtk.Label(label=title, xalign=0)
        lbl.add_css_class("heading")
        box.append(lbl)
        box.append(child)
        return box

    def _flowbox(self, *, max_per_line: int) -> Gtk.FlowBox:
        fb = Gtk.FlowBox()
        fb.set_selection_mode(Gtk.SelectionMode.SINGLE)
        fb.set_max_children_per_line(max_per_line)
        fb.set_min_children_per_line(1)
        fb.set_column_spacing(10)
        fb.set_row_spacing(10)
        fb.set_homogeneous(False)
        fb.set_valign(Gtk.Align.START)
        fb.connect("child-activated", self._on_activated)
        fb.connect("selected-children-changed", self._on_selected)
        return fb

    def _on_map(self) -> None:
        single = self._nautilus_prefs.get_string("click-policy") == "single"
        for fb in (self.folders_box, self.devices_box, self.network_box):
            fb.set_activate_on_single_click(single)
        if self._dirty:
            self.refresh()
        else:
            self._refresh_usage()
        self._start_usage_poll()

    def _on_hub_changed(self) -> None:
        self._dirty = True
        if self.get_mapped():
            self.refresh()

    def refresh(self) -> None:
        self._dirty = False
        self._cancel.cancel()
        self._cancel = Gio.Cancellable()
        for fb in (self.folders_box, self.devices_box, self.network_box):
            fb.remove_all()
        self._cards.clear()

        for special, icon, label in FOLDERS:
            path = os.path.expanduser("~") if special is None else GLib.get_user_special_dir(special)
            if not path or not os.path.isdir(path):
                continue
            if special is not None and os.path.realpath(path) == os.path.realpath(os.path.expanduser("~")):
                continue
            self.folders_box.append(self._folder_tile(
                Gio.File.new_for_path(path).get_uri(), icon, label or os.path.basename(path)))

        n_net = 0
        for dev in self.hub.devices():
            child = self._device_card(dev)
            self._cards[dev.key] = child
            if dev.kind == "network":
                self.network_box.append(child)
                n_net += 1
            else:
                self.devices_box.append(child)
        self.network_section.set_visible(n_net > 0)
        self._refresh_usage()

    def _folder_tile(self, uri: str, icon: str, label: str) -> Gtk.FlowBoxChild:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.add_css_class("vitrine-tile")
        img = Gtk.Image.new_from_icon_name(icon)
        img.set_pixel_size(48)
        lbl = Gtk.Label(label=label, ellipsize=Pango.EllipsizeMode.END, max_width_chars=12)
        box.append(img)
        box.append(lbl)
        child = Gtk.FlowBoxChild()
        child.set_child(box)
        child._vitrine_uri = uri
        child._vitrine_device = None
        self._add_context_menu(child)
        return child

    def _device_card(self, dev: Device) -> Gtk.FlowBoxChild:
        card = Gtk.Box(spacing=12)
        card.add_css_class("card")
        card.add_css_class("vitrine-card")
        card.set_size_request(300, -1)
        img = Gtk.Image()
        if dev.gicon is not None:
            img.set_from_gicon(dev.gicon)
        img.set_pixel_size(48)
        card.append(img)

        info = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, hexpand=True,
                       valign=Gtk.Align.CENTER)
        top = Gtk.Box(spacing=6)
        name = Gtk.Label(label=dev.name, xalign=0, ellipsize=Pango.EllipsizeMode.END)
        name.add_css_class("heading")
        top.append(name)
        badge = Gtk.Label(label="Novo")
        badge.add_css_class("vitrine-badge")
        badge.set_visible(dev.key in self._new_keys)
        top.append(badge)
        info.append(top)
        bar = Gtk.LevelBar(min_value=0, max_value=1)
        bar.add_css_class("vitrine-usage")
        for off in ("low", "high", "full"):
            bar.remove_offset_value(off)
        bar.add_offset_value("vitrine-ok", 0.80)
        bar.add_offset_value("vitrine-warn", 0.92)
        bar.add_offset_value("vitrine-full", 1.0)
        bar.set_visible(dev.mounted)
        info.append(bar)
        detail = Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.END)
        detail.add_css_class("dim-label")
        detail.add_css_class("caption")
        detail.set_text("Calculando…" if dev.mounted else "Não montado. Abra para montar")
        info.append(detail)
        card.append(info)

        if dev.can_eject():
            eject = Gtk.Button(icon_name="media-eject-symbolic", valign=Gtk.Align.CENTER)
            eject.add_css_class("flat")
            eject.add_css_class("circular")
            eject.set_tooltip_text("Remover com segurança" if dev.removable else "Desmontar")
            eject.connect("clicked", lambda *_a, d=dev: self.eject(d))
            card.append(eject)

        child = Gtk.FlowBoxChild()
        child.set_child(card)
        child._vitrine_uri = dev.uri
        child._vitrine_device = dev
        child._vitrine_bar = bar
        child._vitrine_detail = detail
        child._vitrine_badge = badge
        if dev.key in self._new_keys:
            card.add_css_class("vitrine-new")
        self._add_context_menu(child)
        return child

    # ── uso de espaço ──
    def _refresh_usage(self) -> None:
        for child in list(self._cards.values()):
            dev = child._vitrine_device
            if dev is None or not dev.mounted:
                continue
            Gio.File.new_for_uri(dev.uri).query_filesystem_info_async(
                FS_ATTRS, GLib.PRIORITY_LOW, self._cancel, self._on_fs_info, child)

    @guarded
    def _on_fs_info(self, gfile, result, child) -> None:
        try:
            info = gfile.query_filesystem_info_finish(result)
        except GLib.Error:
            child._vitrine_detail.set_text(child._vitrine_device.uri or "")
            child._vitrine_bar.set_visible(False)
            return
        size = info.get_attribute_uint64("filesystem::size")
        free = info.get_attribute_uint64("filesystem::free")
        fstype = info.get_attribute_string("filesystem::type") or ""
        if size <= 0:
            child._vitrine_bar.set_visible(False)
            child._vitrine_detail.set_text(fstype or "—")
            return
        child._vitrine_bar.set_value(max(0.0, min(1.0, (size - free) / size)))
        text = f"{util.human_size(free)} livres de {util.human_size(size)}"
        if fstype:
            text += f" · {fstype}"
        child._vitrine_detail.set_text(text)

    def _start_usage_poll(self) -> None:
        if not self._usage_source:
            self._usage_source = GLib.timeout_add_seconds(USAGE_REFRESH_S, self._poll_usage)

    def _stop_usage_poll(self) -> None:
        if self._usage_source:
            GLib.source_remove(self._usage_source)
            self._usage_source = 0

    def _poll_usage(self) -> bool:
        if not self.get_mapped():
            self._usage_source = 0
            return GLib.SOURCE_REMOVE
        self._refresh_usage()
        return GLib.SOURCE_CONTINUE

    # ── novos dispositivos ──
    def mark_new(self, key: str) -> None:
        """Destaca e seleciona o card de um dispositivo recém-conectado."""
        self._new_keys[key] = time.monotonic()
        GLib.timeout_add_seconds(30, self._unmark, key)
        if self._dirty or key not in self._cards:
            self.refresh()
        child = self._cards.get(key)
        if child is not None:
            child.get_child().add_css_class("vitrine-new")
            child._vitrine_badge.set_visible(True)
            self.devices_box.select_child(child)
            if self.get_mapped():
                child.grab_focus()

    def _unmark(self, key: str) -> bool:
        self._new_keys.pop(key, None)
        child = self._cards.get(key)
        if child is not None:
            child.get_child().remove_css_class("vitrine-new")
            child._vitrine_badge.set_visible(False)
        return GLib.SOURCE_REMOVE

    # ── ações ──
    @guarded
    def _on_activated(self, _fb, child) -> None:
        self.open_child(child)

    @guarded
    def _on_selected(self, fb) -> None:
        sel = fb.get_selected_children()
        if not sel:
            return
        for other in (self.folders_box, self.devices_box, self.network_box):
            if other is not fb:
                other.unselect_all()
        uri = getattr(sel[0], "_vitrine_uri", None)
        self.ctl.preview_location(uri)

    def open_child(self, child, *, new_window: bool = False) -> None:
        dev = getattr(child, "_vitrine_device", None)
        uri = getattr(child, "_vitrine_uri", None)
        if uri:
            self._open_uri(uri, new_window)
        elif dev is not None and dev.volume is not None:
            self.mount_and_open(dev.volume, dev.key, new_window=new_window)

    def _open_uri(self, uri: str, new_window: bool) -> None:
        if new_window:
            util.show_in_new_window(uri)
        else:
            self.ctl.leave_computer_and_open(uri)

    def mount_and_open(self, volume: Gio.Volume, key: str, *, new_window: bool = False) -> None:
        mount = volume.get_mount()
        if mount is not None:
            self._open_uri(mount.get_default_location().get_uri(), new_window)
            return
        self.hub.own_mounts.add(key)
        op = Gtk.MountOperation.new(self.get_root())

        def done(vol, result):
            try:
                vol.mount_finish(result)
            except GLib.Error as err:
                self.hub.own_mounts.discard(key)
                if not err.matches(Gio.io_error_quark(), Gio.IOErrorEnum.FAILED_HANDLED):
                    self.ctl.toast(f"Não foi possível montar {vol.get_name()}: {err.message}")
                return
            m = vol.get_mount()
            if m is not None:
                self._open_uri(m.get_default_location().get_uri(), new_window)

        volume.mount(Gio.MountMountFlags.NONE, op, None, done)

    def eject(self, dev: Device) -> None:
        mount = dev.mount
        if mount is None:
            return
        op = Gtk.MountOperation.new(self.get_root())
        name = dev.name

        def done(m, result, ejecting):
            try:
                if ejecting:
                    m.eject_with_operation_finish(result)
                else:
                    m.unmount_with_operation_finish(result)
            except GLib.Error as err:
                if not err.matches(Gio.io_error_quark(), Gio.IOErrorEnum.FAILED_HANDLED):
                    self.ctl.toast(f"Não foi possível remover {name}: {err.message}")
                return
            self.ctl.toast(f"{name} pode ser removido com segurança" if ejecting
                           else f"{name} foi desmontado")

        if mount.can_eject():
            mount.eject_with_operation(Gio.MountUnmountFlags.NONE, op, None, done, True)
        else:
            mount.unmount_with_operation(Gio.MountUnmountFlags.NONE, op, None, done, False)

    def _launch(self, program: str) -> None:
        try:
            Gio.AppInfo.create_from_commandline(program, None, Gio.AppInfoCreateFlags.NONE).launch(
                [], None)
        except GLib.Error as err:
            log(f"não foi possível abrir {program}: {err.message}")

    # ── menu de contexto ──
    def _add_context_menu(self, child: Gtk.FlowBoxChild) -> None:
        gesture = Gtk.GestureClick.new()
        gesture.set_button(Gdk.BUTTON_SECONDARY)
        gesture.connect("pressed", self._on_right_click, child)
        child.add_controller(gesture)

    @guarded
    def _on_right_click(self, gesture, _n, x, y, child) -> None:
        gesture.set_state(Gtk.EventSequenceState.CLAIMED)
        dev = child._vitrine_device
        uri = child._vitrine_uri
        group = Gio.SimpleActionGroup()
        menu = Gio.Menu()
        top = Gio.Menu()

        def add(section, label, name, fn):
            act = Gio.SimpleAction.new(name, None)
            act.connect("activate", lambda *_a: fn())
            group.add_action(act)
            section.append(label, f"vcomp.{name}")

        add(top, "Abrir" if uri else "Montar e abrir", "open", lambda: self.open_child(child))
        add(top, "Abrir em nova janela", "new-window",
            lambda: self.open_child(child, new_window=True))
        menu.append_section(None, top)
        if uri:
            mid = Gio.Menu()
            path = Gio.File.new_for_uri(uri).get_path() or uri
            add(mid, "Copiar caminho", "copy", lambda: util.copy_text_to_clipboard(child, path))
            menu.append_section(None, mid)
        if dev is not None and dev.can_eject():
            end = Gio.Menu()
            add(end, "Remover com segurança" if dev.mount.can_eject() else "Desmontar", "eject",
                lambda: self.eject(dev))
            menu.append_section(None, end)
        child.insert_action_group("vcomp", group)
        pop = Gtk.PopoverMenu.new_from_model(menu)
        pop.set_parent(child)
        pop.set_has_arrow(False)
        rect = Gdk.Rectangle()
        rect.x, rect.y, rect.width, rect.height = int(x), int(y), 1, 1
        pop.set_pointing_to(rect)
        pop.connect("closed", lambda p: GLib.idle_add(p.unparent))
        pop.popup()
