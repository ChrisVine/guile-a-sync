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

(define-module (a-sync sockets)
  #:use-module (a-sync event-loop)
  #:export (await-accept!
	    await-connect!))

;; This is a convenience procedure whose signature is:
;;
;;   (await-accept! await resume [loop] sock)
;;
;; This procedure will start a watch on listening socket 'sock' for a
;; connection.  'sock' must be a non-blocking socket port.  This
;; procedure wraps the guile 'accept' procedure and therefore returns
;; a pair, comprising as car a connection socket, and as cdr a socket
;; address object containing particulars of the address of the remote
;; connection.  The event loop will not be blocked by this procedure
;; even though no connection is immediately pending, provided that
;; 'sock' is non-blocking.  It is intended to be called within a
;; waitable procedure invoked by a-sync (which supplies the 'await'
;; and 'resume' arguments).
;;
;; The 'loop' argument is optional: this procedure operates on the
;; event loop passed in as an argument, or if none is passed (or #f is
;; passed), on the default event loop.
;;
;; This procedure must (like the a-sync procedure) be called in the
;; same thread as that in which the event loop runs.
;;
;; Exceptions may propagate out of this procedure if they arise from
;; socket errors when first calling the 'accept' procedure.  Subsequent
;; exceptions will propagate out of event-loop-run!.
;;
;; This procedure is first available in version 0.12 of this library.
(define await-accept!
  (case-lambda
    ((await resume sock)
     (await-accept! await resume #f sock))
    ((await resume loop sock)
     (let lp ()
       (let ((ret 
	      (catch 'system-error
		(lambda ()
		  (accept sock))
		(lambda args
		  (if (or (= EAGAIN (system-error-errno args))
			  (and (defined? 'EWOULDBLOCK) 
			       (= EWOULDBLOCK (system-error-errno args))))
		      (begin
			(event-loop-add-read-watch! sock
						    (lambda (status)
						      (resume)
						      #t)
						    loop)
			(await)
			(event-loop-remove-read-watch! sock loop)
			'more)
		      (apply throw args))))))
	 (if (eq? ret 'more)
	     (lp)
	     ret))))))

;; This is a convenience procedure whose signature is:
;;
;;   (await-connect! await resume [loop] sock . args)
;;
;; This procedure will connect socket 'sock' to a remote host.
;; Particulars of the remote host are given by 'args' which are the
;; arguments (other than 'sock') taken by guile's 'connect' procedure,
;; which this procedure wraps.  'sock' must be a non-blocking socket
;; port.  This procedure will return when the connection has been
;; effected, but the event loop will not be blocked even though the
;; connection cannot immediately be made, provided that 'sock' is
;; non-blocking.  It is intended to be called within a waitable
;; procedure invoked by a-sync (which supplies the 'await' and
;; 'resume' arguments).
;;
;; The 'loop' argument is optional: this procedure operates on the
;; event loop passed in as an argument, or if none is passed (or #f is
;; passed), on the default event loop.
;;
;; This procedure must (like the a-sync procedure) be called in the
;; same thread as that in which the event loop runs.
;;
;; Exceptions may propagate out of this procedure if they arise from
;; socket errors when calling the 'connect' procedure.  In the absence
;; of memory exhaustion this procedure should not otherwise throw.
;;
;; This procedure is first available in version 0.12 of this library.
(define (await-connect! await resume next . rest)
  (if (event-loop? next)
      (apply await-connect-impl! await resume next rest)
      (apply await-connect-impl! await resume #f next rest)))

(define (await-connect-impl! await resume loop sock . rest)
  (catch 'system-error
    (lambda ()
      (apply connect sock rest))
    (lambda args
      (if (= EINPROGRESS (system-error-errno args))
	  (begin
	    (event-loop-add-write-watch! sock
					 (lambda (status)
					   (resume)
					   #t)
					 loop)
	    (await)
	    (event-loop-remove-write-watch! sock loop)
	    (let ((status (getsockopt sock SOL_SOCKET SO_ERROR)))
	      (unless (zero? status)
		;; 'system-error is a guile exception but we can
		;; reasonably throw it here as the error is derived
		;; from guile's connect procedure
		(throw 'system-error "await-connect!" "~A"
		       (list (strerror status)) #f))))
	  (apply throw args)))))
