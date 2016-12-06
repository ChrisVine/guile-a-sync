Overview
--------

This library provides a thread safe event loop for guile-2.0
(event-loop.scm) with support for watches on ports/file descriptors
and timeouts, and which permits events to be posted by other tasks.
This includes tasks running on other threads.

It also provides a coroutines interface (coroutines.scm) which
provides await semantics on such events, so as to avoid inversion of
control (aka "callback hell").

See the documentation mentioned below for further details, and the
docs/example.scm and docs/example-glib.scm files.

A separate guile-a-sync2 library is available for guile-2.2 here:
https://github.com/ChrisVine/guile-a-sync2 .  This library and
guile-a-sync2 are parallel installable.  Where a program is to be
heavily i/o based, say it is based on sockets, and guile-2.2 is
available, guile-a-sync2 is recommended as it makes use of guile-2.2's
new suspendable ports, which are very nice.

Installation
------------

When first run from git, or a tarball obtained from github, it is
necessary to set up autotools.  This can be done with:

  ./autogen.sh --prefix=/usr

or on a 64-bit system, probably:

  /autogen.sh --prefix=/usr --libdir=/usr/lib64

This generates a configure script and installs libtool.  Subsequent
configuration can be done just with

  ./configure --prefix=/usr

and

  ./configure --prefix=/usr --libdir=/usr/lib64

respectively.

On a 64 bit system you may also need to include -fPIC in your CFLAGS
options if libtool doesn't do that for you (libtool normally does when
necessary).

After compiling, install with 'make install' as root.

By default, the scheme files provided by this library will be
pre-compiled to guile bytecode and installed with the scheme files in
guile's object file directory.  If that behaviour is not wanted (say,
because a unix-like compile environment is not available which is
acceptable to the compile scripts), then configure with the
--disable-compile-to-bytecode option.

Documentation
-------------

Html documentation is available after installation in the default html
directory for the target installation (normally at
$(prefix)/share/doc/guile-a-sync/html/index.html).

In addition, the documentation can be viewed at github at:
https://github.com/ChrisVine/guile-a-sync/wiki
