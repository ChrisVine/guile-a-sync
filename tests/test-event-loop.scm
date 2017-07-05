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

(use-modules (a-sync event-loop)
	     (rnrs base))   ;; for assert

;; helpers

(define-syntax-rule (test-result expected res)
  (assert (eqv? expected res)))

(define print-result
  ((lambda ()
     (define count 1)
     (lambda ()
       (simple-format #t "~A: Test ~A OK\n" (basename (current-filename)) count)
       (set! count (1+ count))))))

;; Test 1: event-post!

(define main-loop (make-event-loop))
(let ()
  (define count 0)
  (event-post! (lambda ()
		 (set! count (1+ count)))
	       main-loop)
  (event-loop-run! main-loop)
  (test-result 1 count)
  (print-result))
  
;; Test 2: timeout-post! and timeout-remove!

(let ()
  (define count1 0)
  (define count2 0)
  (define tag (timeout-post! 60
			     (lambda ()
			       (if (< count1 3)
				   (set! count1 (1+ count1))
				   (timeout-remove! tag main-loop))
			       #t)
			     main-loop))
  (timeout-post! 100
		 (lambda ()
		   (if (< count2 3)
		       (begin
			 (set! count2 (1+ count2))
			 #t)
		       #f))
		 main-loop)
  (event-loop-run! main-loop)
  (test-result 3 count1)
  (test-result 3 count2)
  (print-result))

;; Test 3: event-loop-block! and event-loop-quit!

(let ()
  (define count 0)
  (call-with-new-thread (lambda ()
			  ;; we don't need mutex here as the main
			  ;; thread only access count before the
			  ;; thread starts and after it ends
			  (set! count (1+ count))
			  (event-post! (lambda ()
					 (event-loop-quit! main-loop))
				       main-loop)))
  (event-loop-block! #t main-loop)
  (event-loop-run! main-loop)
  (test-result 1 count)
  (event-loop-block! #f main-loop)
  (set! count (1+ count))
  ;; this should return immediately with the loop set not to block
  ;; again
  (event-loop-run! main-loop)
  (test-result 2 count)
  (print-result))

;; Test 4: event-loop-add-read-watch!

(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (event-loop-add-read-watch! in
			      (lambda (status)
				(test-result 'in status)
				(let ([ch (read-char in)])
				  (if (not (char=? ch #\x))
				      (begin
					(test-result #\a ch)
					(set! count (1+ count))
					#t)
				      #f)))
			      main-loop)
  (let loop ((count 0))
    (if (< count 3)
	(begin
	  (write-char #\a out)
	  (force-output out)
	  (loop (1+ count))
	(begin
	  (write-char #\x out)
	  (force-output out)))))
  (event-loop-run! main-loop)
  (test-result 3 count)
  (print-result))

;; Test 5: event-loop-add-read-watch! and event-loop-remove-read-watch!

(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (event-loop-add-read-watch! in
			      (lambda (status)
				(test-result 'in status)
				(let ([ch (read-char in)])
				  (if (not (char=? ch #\x))
				      (begin
					(test-result #\a ch)
					(set! count (1+ count)))
				      (event-loop-remove-read-watch! in main-loop))
				  #t))
			      main-loop)
  (let loop ((count 0))
    (if (< count 3)
	(begin
	  (write-char #\a out)
	  (force-output out)
	  (loop (1+ count))
	(begin
	  (write-char #\x out)
	  (force-output out)))))
  (event-loop-run! main-loop)
  (test-result 3 count)
  (print-result))

;; Test 6: event-loop-add-write-watch!

(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (event-loop-add-write-watch! out
			       (lambda (status)
				 (test-result 'out status)
				 (if (< count 3)
				     (begin
				       (set! count (1+ count))
				       (write-char #\a out)
				       (force-output out)
				       #t)
				     (begin
				       (write-char #\x out)
				       (force-output out)
				       #f)))
			       main-loop)
  (event-loop-run! main-loop)
  (let loop ((ch (read-char in))
	     (count 0))
    (if (not (char=? ch #\x))
	(begin
	  (test-result #\a ch)
	  (loop (read-char in) (1+ count)))
	(test-result 3 count)))
  (test-result 3 count)
  (print-result))

;; Test 7: event-loop-add-write-watch! and event-loop-remove-write-watch!

(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (event-loop-add-write-watch! out
			       (lambda (status)
				 (test-result 'out status)
				 (if (< count 3)
				     (begin
				       (set! count (1+ count))
				       (write-char #\a out)
				       (force-output out))
				     (begin
				       (write-char #\x out)
				       (force-output out)
				       (event-loop-remove-write-watch! out main-loop)))
				 #t)
			       main-loop)
  (event-loop-run! main-loop)
  (let loop ((ch (read-char in))
	     (count 0))
    (if (not (char=? ch #\x))
	(begin
	  (test-result #\a ch)
	  (loop (read-char in) (1+ count)))
	(test-result 3 count)))
  (test-result 3 count)
  (print-result))

;; Test 8: event-loop-block! and event-loop-close! (this test needs to
;; come last as it closes the event loop)

(let ()
  (define count 0)
  (call-with-new-thread (lambda ()
			  ;; we don't need mutex here as the main
			  ;; thread only access count before the
			  ;; thread starts and after it ends
			  (set! count (1+ count))
			  (event-post! (lambda ()
					 (event-loop-close! main-loop))
				       main-loop)))
  (event-loop-block! #t main-loop)
  (event-loop-run! main-loop)
  (test-result 1 count)
  (catch 'event-loop-error
    (lambda ()
      (event-loop-run! main-loop))
    (lambda args
      (set! count (1+ count))))
  (test-result 2 count)
  (print-result))

;;;;;;;;;; now the same tests with a default event loop ;;;;;;;;;;

(set-default-event-loop!)

;; Test 9: event-post!

(let ()
  (define count 0)
  (event-post! (lambda ()
		 (set! count (1+ count))))
  (event-loop-run!)
  (test-result 1 count)
  (print-result))
  
;; Test 10: timeout-post! and timeout-remove!

;; set a new default event loop
(set-default-event-loop!)

(let ()
  (define count1 0)
  (define count2 0)
  (define tag (timeout-post! 60
			     (lambda ()
			       (if (< count1 3)
				   (set! count1 (1+ count1))
				   (timeout-remove! tag))
			       #t)))
  (timeout-post! 100
		 (lambda ()
		   (if (< count2 3)
		       (begin
			 (set! count2 (1+ count2))
			 #t)
		       #f)))
  (event-loop-run!)
  (test-result 3 count1)
  (test-result 3 count2)
  (print-result))

;; Test 11: event-loop-block! and event-loop-quit!

(let ()
  (define count 0)
  (call-with-new-thread (lambda ()
			  ;; we don't need mutex here as the main
			  ;; thread only access count before the
			  ;; thread starts and after it ends
			  (set! count (1+ count))
			  (event-post! (lambda ()
					 (event-loop-quit!)))))
  (event-loop-block! #t)
  (event-loop-run!)
  (test-result 1 count)
  (event-loop-block! #f)
  (set! count (1+ count))
  ;; this should return immediately with the loop set not to block
  ;; again
  (event-loop-run!)
  (test-result 2 count)
  (print-result))

;; Test 12: event-loop-add-read-watch!

(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (event-loop-add-read-watch! in
			      (lambda (status)
				(test-result 'in status)
				(let ([ch (read-char in)])
				  (if (not (char=? ch #\x))
				      (begin
					(test-result #\a ch)
					(set! count (1+ count))
					#t)
				      #f))))
  (let loop ((count 0))
    (if (< count 3)
	(begin
	  (write-char #\a out)
	  (force-output out)
	  (loop (1+ count))
	(begin
	  (write-char #\x out)
	  (force-output out)))))
  (event-loop-run!)
  (test-result 3 count)
  (print-result))

;; Test 13: event-loop-add-read-watch! and event-loop-remove-read-watch!

(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (event-loop-add-read-watch! in
			      (lambda (status)
				(test-result 'in status)
				(let ([ch (read-char in)])
				  (if (not (char=? ch #\x))
				      (begin
					(test-result #\a ch)
					(set! count (1+ count)))
				      (event-loop-remove-read-watch! in))
				  #t)))
  (let loop ((count 0))
    (if (< count 3)
	(begin
	  (write-char #\a out)
	  (force-output out)
	  (loop (1+ count))
	(begin
	  (write-char #\x out)
	  (force-output out)))))
  (event-loop-run!)
  (test-result 3 count)
  (print-result))

;; Test 14: event-loop-add-write-watch!

(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (event-loop-add-write-watch! out
			       (lambda (status)
				 (test-result 'out status)
				 (if (< count 3)
				     (begin
				       (set! count (1+ count))
				       (write-char #\a out)
				       (force-output out)
				       #t)
				     (begin
				       (write-char #\x out)
				       (force-output out)
				       #f))))
  (event-loop-run!)
  (let loop ((ch (read-char in))
	     (count 0))
    (if (not (char=? ch #\x))
	(begin
	  (test-result #\a ch)
	  (loop (read-char in) (1+ count)))
	(test-result 3 count)))
  (test-result 3 count)
  (print-result))

;; Test 15: event-loop-add-write-watch! and event-loop-remove-write-watch!

(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (event-loop-add-write-watch! out
			       (lambda (status)
				 (test-result 'out status)
				 (if (< count 3)
				     (begin
				       (set! count (1+ count))
				       (write-char #\a out)
				       (force-output out))
				     (begin
				       (write-char #\x out)
				       (force-output out)
				       (event-loop-remove-write-watch! out)))
				 #t))
  (event-loop-run!)
  (let loop ((ch (read-char in))
	     (count 0))
    (if (not (char=? ch #\x))
	(begin
	  (test-result #\a ch)
	  (loop (read-char in) (1+ count)))
	(test-result 3 count)))
  (test-result 3 count)
  (print-result))

;; Test 16: event-loop-block! and event-loop-close! (this test needs
;; to come last as it closes the event loop)

(let ()
  (define count 0)
  (call-with-new-thread (lambda ()
			  ;; we don't need mutex here as the main
			  ;; thread only access count before the
			  ;; thread starts and after it ends
			  (set! count (1+ count))
			  (event-post! (lambda ()
					 (event-loop-close!)))))
  (event-loop-block! #t)
  (event-loop-run!)
  (test-result 1 count)
  (catch 'event-loop-error
    (lambda ()
      (event-loop-run!))
    (lambda args
      (set! count (1+ count))))
  (test-result 2 count)
  (print-result))

;;;;;;;;;;;;; now tests with a throttled event loop ;;;;;;;;;;;;;

(define throttled-loop (make-event-loop 3 100000))

(define-syntax-rule (get-elapsed-millisecs body0 body1 ...)
  (let ((start-time (get-internal-real-time)))
    body0 body1 ...
    (let ((end-time (get-internal-real-time)))
      (/ (* (- end-time start-time) 1000)
	 internal-time-units-per-second))))

;; Test 17: throttling arguments of make-event-loop

(let ()
  (event-loop-block! #t throttled-loop)
  (event-post!
   (lambda ()
     (let ((thread
	    (call-with-new-thread
	     (lambda ()
	       (get-elapsed-millisecs
		(let loop ((count 0))
		  (if (< count 2)
		      (begin
			(event-post! 
			 (lambda () #f)
			 throttled-loop)
			(loop (1+ count)))
		      (event-post!
		       (lambda ()
			 (event-loop-block! #f throttled-loop))
		       throttled-loop))))))))
       (let ((elapsed-millisecs (join-thread thread)))
	 (assert (>= elapsed-millisecs 99)))))
   throttled-loop)
  
  (event-loop-run! throttled-loop)

  (event-loop-block! #t throttled-loop)
  (event-post!
   (lambda ()
     (let ((thread
	    (call-with-new-thread
	     (lambda ()
	       (get-elapsed-millisecs
		(let loop ((count 0))
		  (if (< count 3)
		      (begin
			(event-post! 
			 (lambda () #f)
			 throttled-loop)
			(loop (1+ count)))
		      (event-post!
		       (lambda ()
			 (event-loop-block! #f throttled-loop))
		       throttled-loop))))))))
       (let ((elapsed-millisecs (join-thread thread)))
	 ;; 100mS + 237mS = 337mS
	 (assert (>= elapsed-millisecs 336)))))
   throttled-loop)
  
  (event-loop-run! throttled-loop)
  (print-result))
