AC_DEFUN([AC_CHECK_COMPILER],
[
  AC_ARG_ENABLE(debug,[  --enable-debug           creates debugging code [default=no]],
  [ 
   if test $enableval = "no"; dnl 
     then ac_use_debug_code="no"
     else ac_use_debug_code="yes"
   fi
  ], [ac_use_debug_code="no"])

  dnl Just for configure --help

  dnl this prevents stupid AC_PROG_CC from adding "-g" to the default CFLAGS
  c_flags_in=$CFLAGS

  AC_PROG_CC
  AC_PROG_CPP

  CFLAGS=$c_flags_in

  if test -z "$CFLAGS"; then 
    if test "$GCC" = "yes"; then
      if test "$ac_use_debug_code" = "yes"; then
        CFLAGS="-g $CFLAGS"
      else
        CFLAGS="-O2 $CFLAGS"
      fi
    else 
      if test "$ac_use_debug_code" = "yes"; then
        AC_CHECK_C_COMPILER_FLAG(g,
          [
            CFLAGS="-g $CFLAGS"
        ])
      else 
        AC_CHECK_C_COMPILER_FLAG(O2,
          [
            CFLAGS="-O2 $CFLAGS"
        ])
      fi
    fi
    if test "$GCC" = "yes"; then
       CFLAGS="$CFLAGS -Wall"
    fi
  fi
])

AC_DEFUN([AC_CHECK_C_COMPILER_FLAG],
[
AC_MSG_CHECKING(whether $CC supports -$1)
flag_cache=`echo $1 | sed 'y%.=/+-%___p_%'`
AC_CACHE_VAL(ac_cv_prog_c_$flag_cache,
[
echo 'int main(void) { return 0; }' >conftest.c
eval "ac_cv_prog_c_$flag_cache=no"
if test -z "`$CC -$1 -c conftest.c 2>&1`"; then
  if test -z "`$CC -$1 -o conftest conftest.o 2>&1`"; then
    eval "ac_cv_prog_c_$flag_cache=yes"
  fi
fi
rm -f conftest*
])
if eval "test \"`echo '$ac_cv_prog_c_'$flag_cache`\" = yes"; then
 AC_MSG_RESULT(yes)
 :
 $2
else
 AC_MSG_RESULT(no)
 :
 $3
fi
])

AC_DEFUN([AC_CHECK_HAVE_MONOTONIC_CLOCK],
[
  AC_MSG_CHECKING(whether the system supports monotonic clocks)
  AC_CACHE_VAL(ac_cv_have_monotonic_clock,
  [
    AC_RUN_IFELSE(
    [
      AC_LANG_PROGRAM(
      [
#include <unistd.h>
      ],
      [
        if (_POSIX_MONOTONIC_CLOCK > 0
           && _POSIX_CLOCK_SELECTION > 0)
           return 0;

        if (_POSIX_MONOTONIC_CLOCK == -1
           || _POSIX_CLOCK_SELECTION == -1)
            return -1;

        if (sysconf(_SC_MONOTONIC_CLOCK) > 0
           && sysconf(_SC_CLOCK_SELECTION) > 0)
           return 0;

        return -1;
      ])
    ],
    [
      ac_cv_have_monotonic_clock="yes"
    ],
    [
      ac_cv_have_monotonic_clock="no"
    ],
    [
      AC_MSG_RESULT([cross-compiling: ])
      ac_cv_have_monotonic_clock="no"
    ])
  ])

  AC_MSG_RESULT([$ac_cv_have_monotonic_clock])
  if test "$ac_cv_have_monotonic_clock" = "yes" ; then
    AC_DEFINE(HAVE_MONOTONIC_CLOCK, 1, [ Define if the system supports monotonic clocks ])
  fi
])

AC_DEFUN([AC_CHECK_COMPILE_SCHEME],
[
  AC_MSG_CHECKING([whether library is to compile scheme files to bytecode])

  AC_ARG_ENABLE(compile-to-bytecode,
  [  --enable-compile-to-bytecode  compile scheme files to bytecode [[default=yes]]],
  [
     if test "x$enableval" != "xno";  then
       compile_scheme=true
       AC_MSG_RESULT([yes])
     else
       compile_scheme=false
       AC_MSG_RESULT([no])
     fi
  ],
  [
    compile_scheme=true
    AC_MSG_RESULT([yes])
  ])
  AM_CONDITIONAL([COMPILE_TO_BYTECODE], [test x$compile_scheme = xtrue])
])

AC_DEFUN([AC_CHECK_GUILE_SITEDIR],
[
  if test -z "$PKG_CONFIG"; then
    AC_PATH_PROG(PKG_CONFIG, pkg-config, no)
  fi
  if test "$PKG_CONFIG" = "no" ; then
    echo "*** The pkg-config script could not be found. Make sure it is"
    echo "*** in your path, or set the PKG_CONFIG environment variable"
    echo "*** to the full path to pkg-config."
    echo "*** Or see http://www.freedesktop.org/software/pkgconfig to get pkg-config."
  else
    AC_MSG_CHECKING([guile-2.0 site directory])
    GUILE20_SITEDIR=`$PKG_CONFIG guile-2.0 --variable=sitedir`
    AC_MSG_RESULT([$GUILE20_SITEDIR])
  fi
  AC_SUBST(GUILE20_SITEDIR)
])
  
