## Process this file with automake to produce Makefile.in

SOURCES = monotonic-time.scm coroutines.scm event-loop.scm thread-pool.scm compose.scm sockets.scm meeting.scm

moduledir = $(GUILE20_SITEDIR)/a-sync
module_DATA = $(SOURCES) gnome-glib.scm

if COMPILE_TO_BYTECODE
GOBJECTS = $(SOURCES:%.scm=%.go)

gobjectsdir = $(GUILE20_OBJDIR)/a-sync
gobjects_DATA = $(GOBJECTS)

CLEANFILES = $(GOBJECTS)

SUFFIXES = .scm .go

.scm.go:
	$(top_builddir)/a-sync/a-sync-compile.sh "$@" "$<"

# make sure that timestamps on object files are after that of source
# files
install-data-hook:
	for files in $(GOBJECTS); do touch -c $(gobjectsdir)/$$files; done
endif

EXTRA_DIST = $(SOURCES) gnome-glib.scm a-sync-compile.sh
