;; Copyright (C) 2016 Chris Vine

;; This library is free software; you can redistribute it and/or
;; modify it under the terms of the GNU Lesser General Public
;; License as published by the Free Software Foundation; either
;; version 3 of the License, or (at your option) any later version.
;; 
;; This library is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; Lesser General Public License for more details.
;; 
;; You should have received a copy of the GNU Lesser General Public
;; License along with this library; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA


;; When using the scheme (gnome gtk) bindings of guile-gnome with
;; guile, in order to provide await semantics on gtk+ callbacks it
;; will normally be necessary to use the 'await' and 'resume'
;; procedures provided by the a-sync procedure in the (a-sync
;; coroutines) module directly (calling 'resume' in the gtk+ callback
;; when ready, and waiting on that callback using 'await').  However
;; when launching timeouts, file watches or idle events on the glib
;; main loop, convenience procedures are possible similar to those
;; provided for the event loop in the (a-sync event-loop) module.
;; These are set out below.
;;
;; Note that the g-idle-add procedure in guile-gnome is suspect -
;; there appears to be a garbage collection issue, and if you call the
;; procedure often enough in a single or multi-threaded program it
;; will eventually segfault.  g-io-add-watch is also broken in
;; guile-gnome, so this file uses its own glib-add-watch procedure
;; which is exported publicly in case it is useful to users.
;;
;; All the other scheme files provided by this library are by default
;; compiled by this library to bytecode.  That is not the case with
;; this file, so as not to create a hard dependency on guile-gnome.

(define-module (a-sync gnome-glib)
  #:use-module (gnome glib)            ;; for g-io-channel-* and g-source-*
  #:use-module (gnome gobject)         ;; for gclosure
  #:use-module (oop goops)             ;; for make
  #:use-module (rnrs bytevectors)      ;; for make-bytevector, bytevector-copy!, bytevector-u8-ref
  #:use-module (rnrs io ports)         ;; for get-u8 and put-u8
  #:use-module ((ice-9 iconv)          ;; (guile-2.0 does not provide the selected procedures in rnrs)
		#:select (bytevector->string string->bytevector)
		#:renamer (symbol-prefix-proc 'iconv:))
  #:use-module (a-sync coroutines)     ;; for make-iterator
  #:export (await-glib-task-in-thread
	    await-glib-task
	    await-glib-yield
	    await-glib-generator-in-thread
	    await-glib-generator
	    await-glib-timeout
	    await-glib-sleep
	    glib-add-watch
	    a-sync-glib-read-watch
	    a-sync-glib-write-watch
	    await-glib-getline
	    await-glib-getblock
	    await-glib-put-bytevector
	    await-glib-put-string))

;; We need to import the definition of the c-write procedure, as
;; provided by unix_write.c. 
(load-extension "libguile-a-sync-0" "init_a_sync_c_write")

;; This is a convenience procedure which will run 'thunk' in its own
;; thread, and then post an event to the default glib main loop when
;; 'thunk' has finished.  This procedure calls 'await' in the default
;; glib main loop and will return the thunk's return value.  It is
;; intended to be called in a waitable procedure invoked by a-sync.
;; If the optional 'handler' argument is provided, then it will be run
;; in the default glib main loop if 'thunk' throws and its return
;; value will be the return value of this procedure; otherwise the
;; program will terminate if an unhandled exception propagates out of
;; 'thunk'.  'handler' should take the same arguments as a guile catch
;; handler (this is implemented using catch).
;;
;; This procedure must (like the a-sync procedure) be called in the
;; same thread as that in which the default glib main loop runs, where
;; the result of calling 'thunk' will be received.  As mentioned
;; above, the thunk itself will run in its own thread.
;;
;; Exceptions may propagate out of this procedure if they arise while
;; setting up (that is, before the worker thread starts), which
;; shouldn't happen unless memory is exhausted or pthread has run out
;; of resources.  Exceptions arising during execution of the task, if
;; not caught by a handler procedure, will terminate the program.
;; Exceptions thrown by the handler procedure will propagate out of
;; g-main-loop-run.
(define* (await-glib-task-in-thread await resume thunk #:optional handler)
  (if handler
      (call-with-new-thread
       (lambda ()
	 (catch
	  #t
	  (lambda ()
	    (let ((res (thunk)))
	      (g-idle-add (lambda ()
			    (resume res)
			    #f))))
	  (lambda args
	    (g-idle-add (lambda ()
			  (resume (apply handler args))
			  #f))))))
      (call-with-new-thread
       (lambda ()
	 (let ((res (thunk)))
	   (g-idle-add (lambda ()
			 (resume res)
			 #f))))))
  (await))

;; This is a convenience procedure for use with glib, which will run
;; 'thunk' in the default glib main loop.  This procedure calls
;; 'await' and will return the thunk's return value.  It is intended
;; to be called in a waitable procedure invoked by a-sync.  It is the
;; single-threaded corollary of await-glib-task-in-thread.  This means
;; that (unlike with await-glib-task-in-thread) while 'thunk' is
;; running other events in the main loop will not make progress, so
;; blocking calls should not be made in 'thunk'.
;;
;; When 'thunk' is executed, this procedure is waiting on 'await', so
;; 'await' and 'resume' cannot be used again in 'thunk' (although
;; 'thunk' can call a-sync to start another series of asynchronous
;; operations with a new await-resume pair).  For that reason,
;; await-glib-yield is usually more convenient for composing
;; asynchronous tasks.  In retrospect, this procedure offers little
;; over await-glib-yield, apart from symmetry with
;; await-glib-task-in-thread.
;;
;; This procedure must (like the a-sync procedure) be called in the
;; same thread as that in which the default glib main loop runs.
;;
;; Exceptions may propagate out of this procedure if they arise while
;; setting up (that is, before the task starts), which shouldn't
;; happen unless memory is exhausted.  Exceptions arising during
;; execution of the task, if not caught locally, will propagate out of
;; g-main-loop-run.
(define (await-glib-task await resume thunk)
  (g-idle-add (lambda ()
		(resume (thunk))
		#f))
  (await))

;; This is a convenience procedure for use with glib, which will
;; surrender execution to the relevant event loop, so that code in
;; other a-sync or compose-a-sync blocks can run.  The remainder of
;; the code after the call to await-yield! in the current a-sync or
;; compose-a-sync block will execute on the next iteration through the
;; loop.  It is intended to be called within a waitable procedure
;; invoked by a-sync (which supplies the 'await' and 'resume'
;; arguments).  It's effect is similar to calling await-task!  with a
;; task that does nothing.
;;
;; This procedure must (like the a-sync procedure) be called in the
;; same thread as that in which the relevant event loop runs: for this
;; purpose "the relevant event loop" is the event loop given by the
;; 'loop' argument, or if no 'loop' argument is provided or #f is
;; provided as the 'loop' argument, then the default event loop.
;;
;; Exceptions may propagate out of this procedure if they arise while
;; setting up (that is, before the task starts), which shouldn't
;; happen unless memory is exhausted.  Exceptions arising in code
;; appearing after the call to this procedure in the a-sync or
;; compose-a-sync block will propagate out of g-main-loop-run.
;;
;; This procedure is first available in version 0.12 of this library.
(define (await-glib-yield await resume)
  (g-idle-add (lambda ()
		(resume)
		#f))
  (await))

;; This is a convenience procedure for acting asynchronously on values
;; yielded by generator procedures.  The 'generator' argument is a
;; procedure taking one argument, namely a yield argument (see the
;; documentation on the make-iterator procedure for further details).
;; This await-glib-generator-in-thread procedure will run 'generator'
;; in its own worker thread, and whenever 'generator' yields a value
;; will cause 'proc' to execute in the default glib main loop.
;;
;; 'proc' should be a procedure taking a single argument, namely the
;; value yielded by the generator.  If the optional 'handler' argument
;; is provided, then that handler will be run in the default glib main
;; loop if 'generator' throws; otherwise the program will terminate if
;; an unhandled exception propagates out of 'generator'.  'handler'
;; should take the same arguments as a guile catch handler (this is
;; implemented using catch).
;;
;; This procedure calls 'await' and will return when the generator has
;; finished or, if 'handler' is provided, upon the generator throwing
;; an exception.  This procedure will return #f if the generator
;; completes normally, or 'guile-a-sync-thread-error if the generator
;; throws an exception and 'handler' is run (the
;; 'guile-a-sync-thread-error symbol is reserved to the implementation
;; and should not be yielded by the generator).
;;
;; This procedure is intended to be called in a waitable procedure
;; invoked by a-sync.  It must (like the a-sync procedure) be called
;; in the same thread as that in which the default glib main loop
;; runs.  As mentioned above, the generator itself will run in its own
;; thread.
;;
;; Exceptions may propagate out of this procedure if they arise while
;; setting up (that is, before the worker thread starts), which
;; shouldn't happen unless memory is exhausted or pthread has run out
;; of resources.  Exceptions arising during execution of the
;; generator, if not caught by a handler procedure, will terminate the
;; program.  Exceptions thrown by the handler procedure will propagate
;; out of g-main-loop-run.  Exceptions thrown by 'proc', if not caught
;; locally, will also propagate out of g-main-loop-run!.
;;
;; This procedure is first available in version 0.9 of this library.
(define* (await-glib-generator-in-thread await resume generator proc #:optional handler)
  (if handler
      (call-with-new-thread
       (lambda ()
	 (catch
	   #t
	   (lambda ()
	     (let ((iter (make-iterator generator)))
	       (let next ((res (iter)))
		 (g-idle-add (lambda ()
			       (resume res)
			       #f))
		 (when (not (eq? res 'stop-iteration))
		   (next (iter))))))
	   (lambda args
	     (g-idle-add (lambda ()
			   (apply handler args)
			   (resume 'guile-a-sync-thread-error)
			   #f))))))
      (call-with-new-thread
       (lambda ()
	 (let ((iter (make-iterator generator)))
	   (let next ((res (iter)))
	     (g-idle-add (lambda ()
			   (resume res)
			   #f))
	     (when (not (eq? res 'stop-iteration))
	       (next (iter))))))))
  (let next ((res (await)))
    (cond
     ((eq? res 'stop-iteration)
      #f)
     ((eq? res 'guile-a-sync-thread-error)
      'guile-a-sync-thread-error)
     (else 
      (proc res)
      (next (await))))))

;; This is a convenience procedure for acting asynchronously on values
;; yielded by generator procedures.  The 'generator' argument is a
;; procedure taking one argument, namely a yield argument (see the
;; documentation on the make-iterator procedure for further details).
;; This await-glib-generator procedure will run 'generator', and
;; whenever 'generator' yields a value will cause 'proc' to execute in
;; the default glib main loop - each time 'proc' runs it will do so as
;; a separate event in the main loop and so be multi-plexed with other
;; events.  'proc' should be a procedure taking a single argument,
;; namely the value yielded by the generator.
;;
;; This procedure is intended to be called in a waitable procedure
;; invoked by a-sync.  It is the single-threaded corollary of
;; await-glib-generator-in-thread.  This means that (unlike with
;; await-glib-generator-in-thread) while 'generator' is running other
;; events in the main loop will not make progress, so blocking calls
;; (other than to the yield procedure) should not be made in
;; 'generator'.
;;
;; When 'proc' executes, this procedure will have released 'await' and
;; 'resume', so they may be used by 'proc' to initiate other
;; asynchronous operations sequentially.
;;
;; This procedure must (like the a-sync procedure) be called in the
;; same thread as that in which the event loop runs.
;;
;; Exceptions may propagate out of this procedure if they arise while
;; setting up (that is, before the task starts), which shouldn't
;; happen unless memory is exhausted.  Exceptions arising during
;; execution of the generator, if not caught locally, will propagate
;; out of await-glib-generator.  Exceptions thrown by 'proc', if not
;; caught locally, will propagate out of g-main-loop-run!.
;;
;; This procedure is first available in version 0.9 of this library.
(define (await-glib-generator await resume generator proc)
  (let ((iter (make-iterator generator)))
    (let next ((res (iter)))
      (g-idle-add (lambda ()
		    (resume res)
		    #f))
      (when (not (eq? res 'stop-iteration))
	(next (iter)))))
  (let next ((res (await)))
    (when (not (eq? res 'stop-iteration))
      (proc res)
      (next (await)))))

;; This is a convenience procedure for use with a glib main loop,
;; which will run 'thunk' in the default glib main loop when the
;; timeout expires.  This procedure calls 'await' and will return the
;; thunk's return value.  It is intended to be called in a waitable
;; procedure invoked by a-sync.  The timeout is single shot only - as
;; soon as 'thunk' has run once and completed, the timeout will be
;; removed from the event loop.
;;
;; In practice, calling await-glib-sleep may often be more convenient
;; for composing asynchronous code than using this procedure.  That is
;; because, when 'thunk' is executed, this procedure is waiting on
;; 'await', so 'await' and 'resume' cannot be used again in 'thunk'
;; (although 'thunk' can call a-sync to start another series of
;; asynchronous operations with a new await-resume pair).  In
;; retrospect, this procedure offers little over await-glib-sleep!.
;;
;; This procedure must (like the a-sync procedure) be called in the
;; same thread as that in which the default glib main loop runs.
;;
;; Exceptions may propagate out of this procedure if they arise while
;; setting up (that is, before the first call to 'await' is made),
;; which shouldn't happen unless memory is exhausted.  Exceptions
;; thrown by 'thunk', if not caught locally, will propagate out of
;; g-main-loop-run.
(define (await-glib-timeout await resume msecs thunk)
  (g-timeout-add msecs
		 (lambda ()
		   (resume (thunk))
		   #f))
  (await))

;; This is a convenience procedure for use with a glib main loop,
;; which will suspend execution of code in the current a-sync or
;; compose-a-sync block for the duration of 'msecs' milliseconds.  The
;; event loop will not be blocked by the sleep - instead any other
;; events in the event loop (including any other a-sync or
;; compose-a-sync blocks) will be serviced.  It is intended to be
;; called within a waitable procedure invoked by a-sync (which
;; supplies the 'await' and 'resume' arguments).
;;
;; Calling this procedure is equivalent to calling await-glib-timeout
;; with a 'proc' argument comprising a lambda expression that does
;; nothing.
;;
;; This procedure must (like the a-sync procedure) be called in the
;; same thread as that in which the default glib main loop runs.
;;
;; Exceptions may propagate out of this procedure if they arise while
;; setting up (that is, before the first call to 'await' is made),
;; which shouldn't happen unless memory is exhausted.  Exceptions
;; arising in code appearing after the call to this procedure in the
;; a-sync or compose-a-sync block concerned will propagate out of
;; g-main-loop-run.
;;
;; This procedure is first available in version 0.12 of this library.
(define (await-glib-sleep await resume msecs)
  (g-timeout-add msecs
		 (lambda ()
		   (resume)
		   #f))
  (await))

;; This procedure replaces guile-gnome's g-io-add-watch procedure,
;; which won't compile.  It attaches a watch on a g-io-channel object
;; to the main context provided, or if none is provided, to the
;; default glib main context (the main program loop).  It returns a
;; glib ID which can be passed subsequently to the g-source-remove
;; procedure.  It should be possible to call this procedure in any
;; thread.
;;
;; 'ioc' is the g-io-condition object to which the watch is to be
;; attached, and 'cond' is a list of symbols (being 'in, 'out, 'pri,
;; 'hup, 'err and 'nval) comprising the events for which the watch is
;; established.
;;
;; 'func' is executed when an event occurs, and takes two arguments:
;; first the g-io-channel object to which the watch has been attached,
;; and second a g-io-condition object indicating the watch condition
;; which has been met (note: the interface for g-io-condition objects
;; is broken in guile-gnome at present).  The watch is ended either by
;; 'func' returning #f, or by applying g-source-remove to the return
;; value of this procedure.  Otherwise the watch will continue.
;;
;; See the documentation on the a-sync-glib-read-watch procedure for
;; some of the difficulties with using g-io-channel watches with
;; guile-gnome.
(define* (glib-add-watch ioc cond func #:optional context)
  (let ((s (g-io-create-watch ioc cond))
        (closure (make <gclosure>
                   #:return-type <gboolean>
                   #:func func)))
    (g-source-set-closure s closure)
    (g-source-attach s context)))

;; This is a convenience procedure for use with a glib main loop,
;; which will run 'proc' in the default glib main loop whenever the
;; file descriptor 'fd' is ready for reading, and apply resume
;; (obtained from a call to a-sync) to the return value of 'proc'.
;; 'proc' should take two arguments, the first of which will be set by
;; glib to the g-io-channel object constructed for the watch and the
;; second of which will be set to the GIOCondition ('in, 'hup or 'err)
;; provided by glib which caused the watch to activate.  It is
;; intended to be called in a waitable procedure invoked by a-sync.
;; The watch is multi-shot - it is for the user to bring it to an end
;; at the right time by calling g-source-remove in the waitable
;; procedure on the id tag returned by this procedure.  Any port for
;; the file descriptor 'fd' is not referenced for garbage collection
;; purposes - it must remain valid while the read watch is active.
;; This procedure is mainly intended as something from which
;; higher-level asynchronous file operations can be constructed, such
;; as the await-glib-getline procedure.
;;
;; File watches in guile-gnome are implemented using a GIOChannel
;; object, and unfortunately GIOChannel support in guile-gnome is
;; decaying.  The only procedure that guile-gnome provides to read
;; from a GIOChannel object is g-io-channel-read-line, which does not
;; work.  One is therefore usually left with having to read from a
;; guile port (whose underlying file descriptor is 'fd') using guile's
;; port input procedures, but this has its own difficulties because
;; either (i) the port has to be unbuffered (say by using the
;; open-file or fdopen procedure with the '0' mode option or the R6RS
;; open-file-input-port procedure with a buffer-mode of none, or by
;; calling setvbuf), or (ii) 'proc' must deal with everything in the
;; port's buffer by calling drain-input, or by looping on char-ready?
;; before returning.  This is because otherwise, if the port is
;; buffered, once the port is read from there may be further
;; characters in the buffer to be dealt with even though the
;; GIOChannel watch does not trigger because there is nothing new to
;; make the file descriptor ready for reading.
;;
;; Because this procedure takes a 'resume' argument derived from the
;; a-sync procedure, it must (like the a-sync procedure) in practice
;; be called in the same thread as that in which the default glib main
;; loop runs.
;;
;; This procedure should not throw an exception unless memory is
;; exhausted, or guile-glib throws for some other reason.  If 'proc'
;; throws, say because of port errors, and the exception is not caught
;; locally, it will propagate out of g-main-loop-run.
(define (a-sync-glib-read-watch resume fd proc)
  (glib-add-watch (g-io-channel-unix-new fd)
		  '(in hup err)
		  (lambda (a b)
		    (resume (proc a b))
		    #t)))
			   
;; This is a convenience procedure for use with a glib main loop,
;; which will start a read watch on 'port' for a line of input.  It
;; calls 'await' while waiting for input and will return the line of
;; text received (without the terminating '\n' character).  The event
;; loop will not be blocked by this procedure even if only individual
;; characters or part characters are available at any one time
;; (although if 'port' references a socket, it should be non-blocking
;; for this to be guaranteed).  It is intended to be called in a
;; waitable procedure invoked by a-sync, and this procedure is
;; implemented using a-sync-glib-read-watch.  If an end-of-file object
;; is encountered which terminates a line of text, a string containing
;; the line of text will be returned (and from version 0.3, if an
;; end-of-file object is encountered without any text, the end-of-file
;; object is returned rather than an empty string).
;;
;; For the reasons explained in the documentation on
;; a-sync-glib-read-watch, this procedure only works correctly if the
;; port passed to the 'port' argument has buffering switched off (say
;; by using the open-file, fdopen or duplicate-port procedure with the
;; '0' mode option, or by calling setvbuf).  This makes the procedure
;; less useful than would otherwise be the case.
;;
;; This procedure must (like the a-sync procedure) be called in the
;; same thread as that in which the default glib main loop runs.
;;
;; Exceptions may propagate out of this procedure if they arise while
;; setting up (that is, before the first call to 'await' is made),
;; which shouldn't happen unless memory is exhausted.  Subsequent
;; exceptions (say, because of port or conversion errors) will
;; propagate out of g-main-loop-run.
;;
;; From version 0.6, the bytes comprising the input text will be
;; converted to their string representation using the encoding of
;; 'port' if a port encoding has been set, or otherwise using the
;; program's default port encoding, or if neither has been set using
;; iso-8859-1 (Latin-1).  Exceptions from conversion errors will, as
;; mentioned, propagate out of g-main-loop-run.  Conversion errors
;; should not arise with iso-8859-1 encoding, although the string may
;; not necessarily have the desired meaning for the program concerned
;; if the input encoding is in fact different.  From version 0.7, this
;; procedure uses the conversion strategy for 'port' (which defaults
;; at program start-up to 'substitute); version 0.6 instead always
;; used a conversion strategy of 'error if encountering unconvertible
;; characters).
;;
;; From version 0.6, this procedure may be used with an end-of-line
;; representation of either a line-feed (\n) or a carriage-return and
;; line-feed (\r\n) combination, as from version 0.6 any carriage
;; return byte will be discarded (this did not occur with earlier
;; versions).
(define (await-glib-getline await resume port)
  (define chunk-size 128)
  (define text (make-bytevector chunk-size))
  (define text-len 0)
  (define (append-byte! u8)
    (when (= text-len (bytevector-length text))
      (let ((tmp text))
	(set! text (make-bytevector (+ text-len chunk-size)))
	(bytevector-copy! tmp 0 text 0 text-len)))
    (bytevector-u8-set! text text-len u8)
    (set! text-len (1+ text-len)))
  (define (make-outstring)
    ;; guile's bytevector->string procedure is non-standard and takes
    ;; an encoding string and not a transcoder as its second argument,
    ;; and an optional conversion strategy as its third: we use the
    ;; port's encoding if it has one (it will if setlocale has been
    ;; called), otherwise the default port encoding, or if none
    ;; latin-1 (which is encoding neutral in guile-2.0).  We also use
    ;; the port's conversion strategy.
    (let ((encoding (or (port-encoding port)
			(fluid-ref %default-port-encoding)
			"ISO-8859-1"))
	  (conversion-strategy (port-conversion-strategy port))
	  (out-bv (make-bytevector text-len)))
      ;; this copies the text twice and therefore is not very
      ;; efficient, but is the best we can do without writing our own
      ;; wrapper in C, and at least it only occurs once for each line
      (bytevector-copy! text 0 out-bv 0 text-len)
      (iconv:bytevector->string out-bv encoding conversion-strategy)))
  (define id (a-sync-glib-read-watch resume
				     (port->fdes port)
				     (lambda (ioc status)
				       (catch #t
					 (lambda ()
					   ;; this doesn't work.  The wrapper does not seem to provide
					   ;; any way of extracting GIOCondition enumeration values
					   ;; which actually works.  However, 'err or 'pri should cause
					   ;; a read of the port to return an eof-object
					   ;; (if (or (eq? status 'pri)
					   ;; 	  (eq? status 'err))
					   ;;     #f
					   (let next ()
					     (let ((u8
						    (catch 'system-error
						      (lambda ()
							(get-u8 port))
						      (lambda args
							(if (or (= EAGAIN (system-error-errno args))
								(and (defined? 'EWOULDBLOCK) 
								     (= EWOULDBLOCK (system-error-errno args))))
							    'more
							    (apply throw args))))))
					       (cond
						((eq? u8 'more)
						 'more)
						((eof-object? u8)
						 (if (= text-len 0)
						     u8
						     (make-outstring)))
						;; just swallow a DOS-style CR character
						((= u8 (char->integer #\return))
						 (if (char-ready? port)
						     (next)
						     'more))
						((= u8 (char->integer #\newline))
						 (make-outstring))
						(else
						 (append-byte! u8)
						 (if (char-ready? port)
						     (next)
						     'more))))))
					 (lambda args
					   (g-source-remove id)
					   (release-port-handle port)
					   (apply throw args))))))
  (let next ((res (await)))
    (if (eq? res 'more)
	(next (await))
	(begin
	  (g-source-remove id)
	  (release-port-handle port)
	  res))))

;; This is a convenience procedure for use with a glib main loop,
;; which will start a read watch on 'port' for a block of data, such
;; as a binary record, of size 'size'.  It calls 'await' while waiting
;; for input and will return a pair, normally comprising as its car a
;; bytevector of length 'size' containing the data, and as its cdr the
;; number of bytes received (which will be the same as 'size' unless
;; an end-of-file object was encountered part way through receiving
;; the data).  The event loop will not be blocked by this procedure
;; even if only individual bytes are available at any one time
;; (although if 'port' references a socket, it should be non-blocking
;; for this to be guaranteed).  It is intended to be called in a
;; waitable procedure invoked by a-sync, and this procedure is
;; implemented using a-sync-glib-read-watch.
;;
;; As mentioned above, if an end-of-file object is encountered after
;; receipt of some but not 'size' bytes, then a bytevector of length
;; 'size' will be returned as car and the actual (lesser) number of
;; bytes inserted in it as cdr.  If an end-of-file object is
;; encountered without any bytes of data, a pair with eof-object as
;; car and #f as cdr will be returned.
;;
;; For the reasons explained in the documentation on
;; a-sync-glib-read-watch, this procedure only works correctly if the
;; port passed to the 'port' argument has buffering switched off (say
;; by using the open-file, fdopen or duplicate-port procedure with the
;; '0' mode option, or by calling setvbuf).  This makes the procedure
;; less useful than would otherwise be the case.
;;
;; This procedure must (like the a-sync procedure) be called in the
;; same thread as that in which the default glib main loop runs.
;;
;; Exceptions may propagate out of this procedure if they arise while
;; setting up (that is, before the first call to 'await' is made),
;; which shouldn't happen unless memory is exhausted.  Subsequent
;; exceptions (say, because of port errors) will propagate out of
;; g-main-loop-run.
;;
;; This procedure is first available in version 0.11 of this library.
(define (await-glib-getblock await resume port size)
  (define bv (make-bytevector size))
  (define index 0)
  (define id (a-sync-glib-read-watch resume
				     (port->fdes port)
				     (lambda (ioc status)
				       (catch #t
					 (lambda ()
					   ;; this doesn't work.  The wrapper does not seem to provide
					   ;; any way of extracting GIOCondition enumeration values
					   ;; which actually works.  However, 'err or 'pri should cause
					   ;; a read of the port to return an eof-object
					   ;; (if (or (eq? status 'pri)
					   ;; 	      (eq? status 'err))
					   ;;     (cons #f #f)
					   (let next ()
					     (let ((u8
						    (catch 'system-error
						      (lambda ()
							(get-u8 port))
						      (lambda args
							(if (or (= EAGAIN (system-error-errno args))
								(and (defined? 'EWOULDBLOCK) 
								     (= EWOULDBLOCK (system-error-errno args))))
							    'more
							    (apply throw args))))))
					       (cond
						((eq? u8 'more)
						 (cons 'more #f))
						((eof-object? u8)
						 (if (= index 0)
						     (cons u8 #f)
						     (cons bv index)))
						(else
						 (bytevector-u8-set! bv index u8)
						 (set! index (1+ index))
						 (if (= index size)
						     (cons bv size)
						     (if (char-ready? port)
							 (next)
							 (cons 'more #f))))))))
					 (lambda args
					   (g-source-remove id)
					   (release-port-handle port)
					   (apply throw args))))))
  (let next ((res (await)))
    (if (eq? (car res) 'more)
	(next (await))
	(begin
	  (g-source-remove id)
	  (release-port-handle port)
	  res))))

;; This is a convenience procedure for use with a glib main loop,
;; which will run 'proc' in the default glib main loop whenever the
;; file descriptor 'fd' is ready for writing, and apply resume
;; (obtained from a call to a-sync) to the return value of 'proc'.
;; 'proc' should take two arguments, the first of which will be set by
;; glib to the g-io-channel object constructed for the watch and the
;; second of which will be set to the GIOCondition ('out or 'err)
;; provided by glib which caused the watch to activate.  It is
;; intended to be called in a waitable procedure invoked by a-sync.
;; The watch is multi-shot - it is for the user to bring it to an end
;; at the right time by calling g-source-remove in the waitable
;; procedure on the id tag returned by this procedure.  Any port for
;; the file descriptor 'fd' is not referenced for garbage collection
;; purposes - it must remain valid while the read watch is active.
;; This procedure is mainly intended as something from which
;; higher-level asynchronous file operations can be constructed.
;;
;; The documentation on the a-sync-glib-read-watch procedure comments
;; about about the difficulties of using GIOChannel file watches with
;; buffered ports.  The difficulties are not quite so intense with
;; write watches, but users are likely to get best results by using
;; unbuffered output ports (say by using the open-file or fdopen
;; procedure with the '0' mode option or the R6RS
;; open-file-output-port procedure with a buffer-mode of none, or by
;; calling setvbuf).
;;
;; Because this procedure takes a 'resume' argument derived from the
;; a-sync procedure, it must (like the a-sync procedure) in practice
;; be called in the same thread as that in which the default glib main
;; loop runs.
;;
;; This procedure should not throw an exception unless memory is
;; exhausted, or guile-glib throws for some other reason.  If 'proc'
;; throws, say because of port errors, and the exception is not caught
;; locally, it will propagate out of g-main-loop-run.
(define (a-sync-glib-write-watch resume fd proc)
  (glib-add-watch (g-io-channel-unix-new fd)
		  '(out err)
		  (lambda (a b)
		    (resume (proc a b))
		    #t)))

(define (_throw-exception-if-regular-file fd)
  (when (eq? 'regular (stat:type (stat fd)))
    (throw 'c-write-error
	   "_throw-exception-if-regular-file"
	   "await-glib-put-bytevector procedure cannot be used with regular files")))

;; This is a convenience procedure which will start a write watch on
;; 'port' for writing the contents of a bytevector 'bv' to the port.
;; It calls 'await' while waiting for output to become available.  The
;; event loop will not be blocked by this procedure even if only
;; individual bytes can be written at any one time (although if 'port'
;; references a socket, it should be non-blocking for this to be
;; guaranteed).  It is intended to be called in a waitable procedure
;; invoked by a-sync, and this procedure is implemented using
;; a-sync-glib-write-watch.
;;
;; For reasons of efficiency, this procedure by-passes the port's
;; output buffer (if any) and sends the output to the underlying file
;; descriptor directly.  This means that it is most convenient for use
;; with unbuffered ports.  However, this procedure can be used with a
;; port with buffered output, but if that is done and the port has
;; previously been used for output by a procedure other than c-write
;; or an await-glib-put* procedure, then it should be flushed before
;; this procedure is called.  Such flushing might block.
;;
;; This procedure will throw a 'c-write-error exception if passed a
;; regular file with a file position pointer: there should be no need
;; to use this procedure with regular files, because they cannot
;; normally block on write and are always signalled as ready.
;;
;; This procedure must (like the a-sync procedure) be called in the
;; same thread as that in which the event loop runs.
;;
;; Exceptions may propagate out of this procedure if they arise while
;; setting up (that is, before the first call to 'await' is made),
;; which shouldn't happen unless memory is exhausted or a regular file
;; is passed to this procedure.  Subsequent exceptions (say, because
;; of port errors) will propagate out of g-main-loop-run.
;;
;; This procedure is first available in version 0.11 of this library.
(define (await-glib-put-bytevector await resume port bv)
  (define length (bytevector-length bv))
  (define fd (fileno port))
  (_throw-exception-if-regular-file fd)

  (let ((index (c-write fd bv 0 length)))
    ;; for testing
    ;;(let ((index 0))
    ;; set up write watch if we haven't written everything
    (if (< index length)
	(letrec ((id (a-sync-glib-write-watch resume
					      (port->fdes port)
					      (lambda (ioc status)
						(catch #t
						  (lambda ()
						    (set! index (+ index (c-write fd
										  bv
										  index
										  (- length index))))
						    (if (< index length)
							'more
							#f))
						  (lambda args
						    (g-source-remove id)
						    (release-port-handle port)
						    (apply throw args)))))))
	  (let next ((res (await)))
	    (if (eq? res 'more)
		(next (await))
		(begin
		  (g-source-remove id)
		  (release-port-handle port))))))))

;; This is a convenience procedure which will start a write watch on
;; 'port' for writing a string to the port.  It calls 'await' while
;; waiting for output to become available.  The event loop will not be
;; blocked by this procedure even if only individual characters or
;; part characters can be written at any one time (although if 'port'
;; references a socket, it should be non-blocking for this to be
;; guaranteed).  It is intended to be called in a waitable procedure
;; invoked by a-sync, and this procedure is implemented using
;; await-glib-put-bytevector.
;;
;; For reasons of efficiency, this procedure by-passes the port's
;; output buffer (if any) and sends the output to the underlying file
;; descriptor directly.  This means that it is most convenient for use
;; with unbuffered ports.  However, this procedure can be used with a
;; port with buffered output, but if that is done and the port has
;; previously been used for output by a procedure other than c-write
;; or an await-glib-put* procedure, then it should be flushed before
;; this procedure is called.  Such flushing might block.
;;
;; This procedure will throw a 'c-write-error exception if passed a
;; regular file with a file position pointer: there should be no need
;; to use this procedure with regular files, because they cannot
;; normally block on write and are always signalled as ready.
;;
;; This procedure must (like the a-sync procedure) be called in the
;; same thread as that in which the event loop runs.
;;
;; Exceptions may propagate out of this procedure if they arise while
;; setting up (that is, before the first call to 'await' is made),
;; which shouldn't happen unless memory is exhausted, a conversion
;; error is encountered or a regular file is passed to this procedure.
;; Subsequent exceptions (say, because of port errors) will propagate
;; out of g-main-loop-run.
;;
;; The bytes to be sent will be converted from the passed in string
;; representation using the encoding of 'port' if a port encoding has
;; been set, or otherwise using the program's default port encoding,
;; or if neither has been set using iso-8859-1 (Latin-1).  Exceptions
;; from conversion errors will propagate out of this procedure when
;; setting up if conversion fails and a conversion strategy of 'error
;; is in effect.  This procedure uses the conversion strategy for
;; 'port' (which defaults at program start-up to 'substitute).
;;
;; If CR-LF line endings are to be written when outputting the string,
;; the '\r' character (as well as the '\n' character) must be embedded
;; in the string.
;;
;; This procedure is first available in version 0.10 of this library.
(define (await-glib-put-string await resume port text)
  (define bv
    (let ((encoding (or (port-encoding port)
			(fluid-ref %default-port-encoding)
			"ISO-8859-1"))
	  (conversion-strategy (port-conversion-strategy port)))
      (iconv:string->bytevector text encoding conversion-strategy)))
  (await-glib-put-bytevector await resume port bv))
