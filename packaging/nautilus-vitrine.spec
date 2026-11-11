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
