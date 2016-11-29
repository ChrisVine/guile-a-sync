#!/usr/bin/guile
!#

;; Copyright (C) 2016 Chris Vine
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
;; myip.dnsdynamic.org.  Normally if you wanted to do this from a
;; utility script, you would do it synchronously using guile's built
;; in web support module.  However in a program using an event loop,
;; you would need to do it asynchronously.  This does so.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(use-modules
 (a-sync coroutines)
 (a-sync event-loop))

(define check-ip "myip.dnsdynamic.org")

(define (read-response-async await resume sockport)
  (define header "")
  (define body "")
  (await-geteveryline! await resume sockport
		       (lambda (line)
			 (cond
			  ((not (string=? body ""))
			   (set! body (string-append body "\n" line)))
			  ((string=? line "")
			   (set! body (string (integer->char 0)))) ;; marker
			  (else
			   (set! header (if (string=? header "")
					    line
					    (string-append header "\n" line)))))))
  ;; get rid of marker (with \n) in body
  (set! body (substring body 2 (string-length body)))
  (values header body))

(define (send-get-request-async await resume host path sockport)
  (await-put-string! await resume sockport
		     (string-append "GET " path " HTTP/1.1\r\nHost: "host"\r\n\r\n")))

(set-default-event-loop!)

(a-sync
 (lambda (await resume)
   (let ((sockport (socket PF_INET SOCK_STREAM 0)))
     ;; getaddrinfo in particular can block, so call it up with
     ;; connect in either await-task-in-thread! or
     ;; await-task-in-event-loop!
     (await-task-in-thread! await resume
			    (lambda ()
			      (connect sockport
				       (addrinfo:addr (car (getaddrinfo check-ip "http"))))))
     ;; we need a separate output port which is not buffered.  As this
     ;; is a socket, with no file position pointer, creating a new
     ;; output port is fine.
     (let ((out-sockport (duplicate-port sockport "w0")))
       ;; make socket ports non-blocking
       (fcntl sockport F_SETFL (logior O_NONBLOCK
				       (fcntl sockport F_GETFL)))
       (fcntl out-sockport F_SETFL (logior O_NONBLOCK
					   (fcntl out-sockport F_GETFL)))
       (send-get-request-async await resume check-ip "/" out-sockport)
       (call-with-values
	   (lambda ()
	     (read-response-async await resume sockport))
	 (lambda (header body)
	   (display body)
	   (newline)))
       (event-loop-block! #f)))))
  
(event-loop-block! #t)
(event-loop-run!)
