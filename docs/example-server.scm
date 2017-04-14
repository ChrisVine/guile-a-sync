#!/usr/bin/env guile
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

;; This is an example file for an asynchronous socket server.  It is
;; just an echo-bot - it will echo back whatever is sent to it.
;;
;; You can connect to it with: 'telnet ::1 8000'.  Any number of
;; telnet sessions (subject to not exceeding FD_SETSIZE) can be run
;; concurrently.  When the last telnet client has disconnected, the
;; server will finish.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(use-modules
 (a-sync coroutines)
 (a-sync event-loop)
 (a-sync sockets))


(set-default-event-loop!)
(sigaction SIGPIPE SIG_IGN) ;; we want EPIPE, not SIGPIPE

(define count 0)
(define server-sock #f)

(define (handle-conversation conn-sock)
  (a-sync (lambda (await resume)
	    (let next ((line (await-getline! await resume conn-sock)))
	      (if (not (string=? line ""))
		  (begin
		    (await-put-string! await resume conn-sock (string-append "echo: " line "\n"))
		    (next (await-getline! await resume conn-sock)))
		  (begin
		    (shutdown conn-sock 2)
		    (close-port conn-sock)
		    (set! count (- count 1))
		    (when (zero? count)
		      (event-loop-quit!))))))))

(define (start-server)
  (a-sync (lambda (await resume)
	    (set! server-sock (socket PF_INET6 SOCK_STREAM 0))
	    (setsockopt server-sock SOL_SOCKET SO_REUSEADDR 1)
	    ;; make socket non-blocking
	    (fcntl server-sock F_SETFL (logior O_NONBLOCK
					(fcntl server-sock F_GETFL)))
	    (bind server-sock AF_INET6 (inet-pton AF_INET6 "::1") 8000)
	    (listen server-sock 5)
	    (let loop ((accept-pair (await-accept! await resume server-sock)))
	      (let ((conn-sock (car accept-pair))
		    (conn-addr (cdr accept-pair)))
		;; make socket non-blocking
		(fcntl conn-sock F_SETFL (logior O_NONBLOCK
						 (fcntl conn-sock F_GETFL)))
		;; socket ports are unbuffered by default, so make the
		;; connection socket buffered (as this is a socket,
		;; with no file position pointer, keeping port buffers
		;; synchronized is not an issue, and await-put-string!
		;; bypasses the output buffer)
		(setvbuf conn-sock _IOLBF)
		(set! count (+ count 1))
		(await-put-string! await resume conn-sock
				   (string-append
				    "Hello.  Please send some text and I will echo it back\n"
				    "Enter an empty line to finish\n"))
		(simple-format #t "connected to ~a~%"
			       (inet-ntop AF_INET6 (sockaddr:addr conn-addr)))
		(handle-conversation conn-sock)
		(loop (await-accept! await resume server-sock)))))))

(start-server)
(event-loop-run!)
(display "Closing server\n")
(shutdown server-sock 2)
(close-port server-sock)
