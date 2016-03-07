#!/usr/bin/env guile
!#

;; Copyright Chris Vine 2014 and 2016
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


(use-modules (a-sync event-loop) (a-sync coroutines))

(define main-loop (make-event-loop))

(a-sync (lambda (await resume)

	  ;; invoke a one second timeout which does not block the
	  ;; event loop
	  (display "Beginning timeout\n")
	  (display (await-timeout! await resume main-loop 1000
				   (lambda ()
				     "Timeout ended\n")))

	  ;; launch asynchronous task: let's pretend its time
	  ;; consuming so we need to run it in a worker thread
	  ;; to avoid blocking any other events in the main loop
	  ;; (there aren't any in this example)
	  (display (await-task-in-thread! await resume main-loop
					  (lambda ()
					    (usleep 500000)
					    (display "In worker thread, work done\n")
					    ;; this is the result of our extensive computation
					    "Hello via async\n")))

	  ;; obtain a line of text from a port (in this case, the
	  ;; keyboard)
	  (display "Enter a line of text at the keyboard\n")
	  (system* "stty" "--file=/dev/tty" "cbreak")
	  (simple-format #t
			 "The line was: ~A\n"
			 (await-getline! await resume
					 main-loop
					 (open "/dev/tty" O_RDONLY)))
	  (system* "stty" "--file=/dev/tty" "-cbreak")

	  ;; launch another asynchronous task, this time in the event loop thread
	  (display (await-task! await resume main-loop
				(lambda ()
				  (event-loop-quit! main-loop)
				  "Quitting\n")))))

;; because one task runs in another thread
(event-loop-block! main-loop #t)
(event-loop-run! main-loop)
