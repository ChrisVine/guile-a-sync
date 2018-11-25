dnl Process this file with autoconf to produce a configure script.
AC_INIT([guile-a-sync], [0.23])

dnl Require autoconf 2.59c or greater for docdir and htmldir
AC_PREREQ(2.59c)

dnl Set so_version info for libtool (set with -version-info in lib/Makefile.am)
dnl CURRENT : REVISION : AGE where
dnl CURRENT =  The most recent interface number that this library implements.
dnl REVISION = The implementation number of the current interface.
dnl AGE =      The difference between the newest and oldest interface numbers
dnl            that this library implements (ie a range so that AGE must be
dnl            less than or equal to CURRENT)
dnl
dnl +1 : ? : +1  == new interface that does not break old one
dnl +1 : ? : 0   == new interface that breaks old one
dnl  ? : ? : 0   == no new interfaces, but breaks apps
dnl  ? :+1 : ?   == just some internal changes, nothing breaks (eg bump with
dnl                 minor/micro library version number changes changing
dnl                 compiled code but no new interface)
GUILE_A_SYNC_SO_VERSION=0:0:0
AC_SUBST(GUILE_A_SYNC_SO_VERSION)

AM_INIT_AUTOMAKE([1.11])

AC_CONFIG_HEADERS([config.h])

dnl check for working c compiler
AC_CHECK_COMPILER

dnl set up libtool
AC_PROG_LIBTOOL
AC_CONFIG_MACRO_DIR([m4])

dnl check for guile
PKG_CHECK_MODULES(GUILE, guile-2.0 >= 2.0.9)
AC_CHECK_GUILE_SITEDIR
AC_CHECK_GUILE_OBJDIR

dnl check whether to compile scheme files to bytecode
AC_CHECK_COMPILE_SCHEME

dnl check if we have a monotonic clock
AC_CHECK_HAVE_MONOTONIC_CLOCK

dnl Check for POSIX headers.
AC_CHECK_HEADERS([ unistd.h errno.h time.h ],
                 [:],[AC_MSG_ERROR([Standard POSIX headers not found], 1)])

dnl define MAKE for subdirectories
AC_PROG_MAKE_SET

AC_CONFIG_FILES([ Makefile a-sync/Makefile lib/Makefile docs/Makefile \
                  tests/Makefile guile-a-sync.pc ])
AC_OUTPUT
