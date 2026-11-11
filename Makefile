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
