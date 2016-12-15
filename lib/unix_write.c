/*
  Copyright (C) 2016 Chris Vine

  This library is free software; you can redistribute it and/or modify
  it under the terms of the GNU Lesser General Public License as
  published by the Free Software Foundation; either version 3 of the
  License, or (at your option) any later version.
 
  This library is distributed in the hope that it will be useful, but
  WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
  Lesser General Public License for more details.
 
  You should have received a copy of the GNU Lesser General Public
  License along with this library; if not, write to the Free Software
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
  02110-1301 USA
*/

#include <unistd.h>
#include <errno.h>

#include <libguile.h>


/*
  The c-write procedure is used by await-put-bytevector! (and so by
  await-put-string!) and is exported by event-loop.scm so that it can
  be used by other asynchronous procedures.  It makes a block write
  directly to output, bypassing any output buffers, using unix write.
  It is intended for use with asynchronous procedures which write
  blocks of data, to enable them to do so efficiently.

  This procedure provides a 'begin' parameter indicating the start of
  the sequence of bytes to be written, as an index.  'fd' is the file
  descriptor of the device to be written to, and it should be
  non-blocking.  'bv' is a bytevector containing the bytes to be
  written.  'count' is the maximum number of bytes to be written.
  Because this procedure is intended for use with non-blocking ports,
  it may write less than 'count' bytes: only the number of bytes
  available to the device to be written to will be written at any one
  time.  The sum of 'begin' and 'count' must not be more than the
  length of the bytevector.  The use of a separate 'begin' index
  enables the same bytevector to be written from repeatedly until all
  of it has been sent.

  Provided 'fd' is non-blocking, this procedure returns immediately
  with the number of bytes written (so 0 is returned if the file
  descriptor is not available for writing because the device is full).
  On a write error other than EAGAIN, EWOULDBLOCK or EINTR, a
  'c-write-error exception is thrown and errno is given as an argument
  to the exception handler.  EINTR is handled internally and is not an
  error.

  This procedure is first available in version 0.11 of this library.
*/
static SCM c_write(SCM fd, SCM bv, SCM begin, SCM count) {
  ssize_t ret;

  int c_fd = scm_to_int(fd);
  void* c_buf = scm_to_pointer(scm_bytevector_to_pointer(bv, begin));
  size_t c_count = scm_to_size_t(count);

  do {
    ret = write(c_fd, c_buf, c_count);
  } while (ret == -1 && errno == EINTR);
  if (ret == -1) {
    if (errno == EAGAIN || errno == EWOULDBLOCK)
      return scm_from_ssize_t(0);
    else
      scm_throw(scm_string_to_symbol(scm_from_locale_string("c-write-error")),
		(scm_list_3((scm_from_locale_string("c-write")),
			    (scm_from_locale_string("errno: ~A")),
			    (scm_list_1(scm_from_int(errno))))));
  }
  return scm_from_ssize_t(ret);
}

void init_a_sync_c_write(void* unused) {
  scm_c_define_gsubr("c-write", 4, 0, 0, c_write);
  scm_c_export("c-write", NULL);
}
