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
