## Process this file with automake to produce Makefile.in

SOURCES = monotonic-time.scm coroutines.scm event-loop.scm compose.scm sockets.scm meeting.scm thread-pool.scm

moduledir = $(GUILE20_SITEDIR)/a-sync
module_DATA = $(SOURCES) gnome-glib.scm

if COMPILE_TO_BYTECODE
GOBJECTS = $(SOURCES:%.scm=%.go)

gobjectsdir = $(GUILE20_OBJDIR)/a-sync
gobjects_DATA = $(GOBJECTS)

CLEANFILES = $(GOBJECTS)

# we state dependencies here rather than use a generalized SUFFIXES
# target to handle dependencies for parallel compilation better
monotonic-time.go: monotonic-time.scm
	$(top_builddir)/a-sync/a-sync-compile.sh monotonic-time.scm "$@"
coroutines.go: coroutines.scm
	$(top_builddir)/a-sync/a-sync-compile.sh coroutines.scm "$@"
event-loop.go: event-loop.scm monotonic-time.go coroutines.go
	$(top_builddir)/a-sync/a-sync-compile.sh event-loop.scm "$@"
compose.go: compose.scm coroutines.go
	$(top_builddir)/a-sync/a-sync-compile.sh compose.scm "$@"
sockets.go: sockets.scm event-loop.go
	$(top_builddir)/a-sync/a-sync-compile.sh sockets.scm "$@"
meeting.go: meeting.scm event-loop.go
	$(top_builddir)/a-sync/a-sync-compile.sh meeting.scm "$@"
thread-pool.go: thread-pool.scm coroutines.go event-loop.go
	$(top_builddir)/a-sync/a-sync-compile.sh thread-pool.scm "$@"

# make sure that timestamps on object files are after that of source
# files
install-data-hook:
	for files in $(GOBJECTS); do touch -c $(gobjectsdir)/$$files; done
endif

EXTRA_DIST = $(SOURCES) gnome-glib.scm a-sync-compile.sh
