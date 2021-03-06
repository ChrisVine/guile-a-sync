#!/usr/bin/env guile
!#

;; Copyright (C) 2016 to 2019 Chris Vine
;;
;; Permission is hereby granted, free of charge, to any person
;; obtaining a copy of this file (the "Software"), to deal in the
;; Software without restriction, including without limitation the
;; rights to use, copy, modify, merge, publish, distribute,
;; sublicense, and/or sell copies of the Software, and to permit
;; persons to whom the Software is furnished to do so, subject to the
;; following conditions:
;;
;; The above copyright notice and this permission notice shall be
;; included in all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;; NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
;; BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
;; ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
;; CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; This is an example file for using asynchronous reads and writes on
;; sockets.  It will provide the caller's IPv4 internet address from
;; checkip.dyndns.com.  Normally if you wanted to do this from a
;; utility script, you would do it synchronously using guile's built
;; in web support module.  However in a program using an event loop,
;; you would need to do it asynchronously.  This does so.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(use-modules
 (ice-9 regex)
 (a-sync coroutines)
 (a-sync event-loop)
 (a-sync sockets))

(define check-ip "checkip.dyndns.com")

(define (await-read-response await resume sock)
  (define header-done #f)
  (define header "")
  (define body "")
  (await-geteveryline! await resume sock
		       (lambda (line)
			 (if header-done
			     (if (string=? body "")
				 (set! body line)
				 (set! body (string-append body "\n" line)))
			     (if (string=? line "")
				 (set! header-done #t)
				 (if (string=? header "")
				     (set! header line)
				     (set! header (string-append header "\n" line)))))))
  (values header body))

(define (await-send-get-request await resume host path sock)
  (await-put-string! await resume sock
  		     (string-append "GET " path " HTTP/1.1\r\nHost: " host "\r\nConnection: close\r\n\r\n")))

(set-default-event-loop!)
(sigaction SIGPIPE SIG_IGN) ;; we want EPIPE, not SIGPIPE
(event-loop-block! #t)  ;; we invoke await-task-in-thread!

(a-sync
 (lambda (await resume)
   (let ((sock (socket PF_INET SOCK_STREAM 0))
	 ;; getaddrinfo can block, so call it up with
	 ;; await-task-in-thread!, await-task-in-event-loop! or
	 ;; await-task-in-thread-pool!
	 (addr (await-task-in-thread! await resume
				      (lambda ()
					(addrinfo:addr (car (getaddrinfo check-ip "http")))))))
     ;; make socket non-blocking
     (fcntl sock F_SETFL (logior O_NONBLOCK
				 (fcntl sock F_GETFL)))
     ;; socket ports are unbuffered by default, so make the socket
     ;; buffered (as this is a socket, with no file position pointer,
     ;; keeping port buffers synchronized is not an issue, and
     ;; await-put-string! bypasses the output buffer)
     (setvbuf sock _IOLBF)
     (await-connect! await resume sock addr)
     (await-send-get-request await resume check-ip "/" sock)
     (call-with-values
	 (lambda ()
	   (await-read-response await resume sock))
       (lambda (header body)
	 (let ((ip (match:substring 
		    (string-match "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" body))))
	   (display ip)
	   (newline))))
     (event-loop-block! #f))))

(event-loop-run!)
