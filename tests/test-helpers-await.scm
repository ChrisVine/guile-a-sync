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

(use-modules (a-sync coroutines)
	     (a-sync event-loop)
	     (a-sync compose)
	     (ice-9 rdelim) ;; for write-line
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

;; Test 1: await-task!

(define main-loop (make-event-loop))

(a-sync (lambda (await resume)
	  (let ((res
		 (await-task! await resume main-loop
			      (lambda ()
				(+ 5 10)))))
	    (test-result 15 res)
	    (print-result))))
(event-loop-run! main-loop)

;; Test 2: await-task-in-thread! without handler

(a-sync (lambda (await resume)
	  (let ((res
	  	 (await-task-in-thread! await resume main-loop
	  				(lambda ()
	  				  (+ 5 10)))))
	    (test-result 15 res)
	    (print-result)
	    (event-loop-quit! main-loop))))
(event-loop-block! #t main-loop)
(event-loop-run! main-loop)
(event-loop-block! #f main-loop)
  
;; Test 3: await-task-in-thread! with handler

(a-sync (lambda (await resume)
	  (let ((res
	  	 (await-task-in-thread!
		  await resume main-loop
		  (lambda () (throw 'test-exception))
		  (lambda (key . args)
		    (test-result 'test-exception key)
		    5))))
	    (test-result 5 res)
	    (print-result)
	    (event-loop-quit! main-loop))))
(event-loop-block! #t main-loop)
(event-loop-run! main-loop)
(event-loop-block! #f main-loop)

;; Test 4: await-task-in-event-loop!

(let ()
  (define worker (make-event-loop 10 100000))

  (event-loop-block! #t main-loop)
  (event-loop-block! #t worker)

  (call-with-new-thread
   (lambda ()
     (event-loop-run! worker)))

  (a-sync (lambda (await resume)
	    (let ((res
		   (await-task-in-event-loop! await resume main-loop worker
					      (lambda ()
						(+ 5 10)))))
	      (test-result 15 res)
	      (print-result)
	      (event-loop-block! #f main-loop)
	      (event-loop-block! #f worker))))
  (event-loop-run! main-loop))

;; Test 5: await-timeout!

(a-sync (lambda (await resume)
	  (let ((res
		 (await-timeout! await resume main-loop 10
				 (lambda ()
				   (+ 5 10)))))
	    (test-result 15 res)
	    (print-result))))
(event-loop-run! main-loop)
  
;; Test 6: await-getline! (also tests a-sync-read-watch!)

(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (a-sync (lambda (await resume)
	    (let ((res (await-getline! await resume
				       main-loop
				       in)))
	      (assert (string=? res "test-string"))
	      (print-result))))
  (write-line "test-string" out)
  (force-output out)
  (event-loop-run! main-loop))

;; Test 7: await-geteveryline! (also tests a-sync-read-watch!)

(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (a-sync (lambda (await resume)
	    (let ((res (await-geteveryline! await resume
					    main-loop
					    in
					    (lambda (line)
					      (set! count (1+ count))
					      (when (= count 1)
						(assert (string=? line "test-string1")))
					      (when (= count 2)
						(assert (string=? line "test-string2"))
						(close out))))))
	      (assert (eof-object? res))
	      (test-result 2 count)
	      (print-result))))
  (write-line "test-string1" out)
  (write-line "test-string2" out)
  (force-output out)
  (event-loop-run! main-loop))

;; Test 8: await-getsomelines! (also tests a-sync-read-watch!)

(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (a-sync (lambda (await resume)
	    (let ((res (await-getsomelines! await resume
					    main-loop
					    in
					    (lambda (line k)
					      (set! count (1+ count))
					      (when (= count 1)
						    (assert (string=? line "test-string1")))
					      (when (= count 2)
						    (assert (string=? line "test-string2")))
					      (when (= count 3)
						    (assert (string=? line "test-string3"))
						    (k 'exit-await))))))
	      (assert (eq? res 'exit-await))
	      (test-result 3 count)
	      (print-result))))
  (write-line "test-string1" out)
  (write-line "test-string2" out)
  (write-line "test-string3" out)
  (force-output out)
  (event-loop-run! main-loop)
  (close out))

;; Test 9: await-getsomelines! exception handling (also tests strategy for await-geteveryline!)
;; exception propagates out of event-loop-run!
(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (a-sync (lambda (await resume)
	    (await-getsomelines! await resume
				 main-loop
				 in
				 (lambda (line k)
				   (set! count (1+ count))
				   (when (= count 1)
					 (assert (string=? line "test-string1")))
				   (when (= count 2)
					 (throw 'exit-exception))
				   (when (= count 3)
					 (assert #f)))) ;; we should never reach here
	    (assert #f))) ;; we should never reach here
  (write-line "test-string1" out)
  (write-line "test-string2" out)
  (write-line "test-string3" out)
  (force-output out)
  (catch #t
	 (lambda ()
	   (event-loop-run! main-loop)
	   (assert #f)) ;; we should never reach here
	 (lambda args
	   (assert (eq? (car args) 'exit-exception))))
  (close out)
  (test-result 2 count)
  (print-result))

;; Test 10: await-getsomelines! exception handling (also tests strategy for await-geteveryline!)
;; exception caught within a-sync block
(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (a-sync (lambda (await resume)
	    (catch #t
		   (lambda ()
		     (await-getsomelines! await resume
					  main-loop
					  in
					  (lambda (line k)
					    (set! count (1+ count))
					    (when (= count 1)
						  (assert (string=? line "test-string1")))
					    (when (= count 2)
						  (throw 'exit-exception))
					    (when (= count 3)
						  (assert #f))))   ;; we should never reach here
		     (assert #f))   ;; we should never reach here
		   (lambda args
		     (assert (eq? (car args) 'exit-exception))))))
  (write-line "test-string1" out)
  (write-line "test-string2" out)
  (write-line "test-string3" out)
  (force-output out)
  (event-loop-run! main-loop)
  (close out)
  (test-result 2 count)
  (print-result))

;; Test 11: a-sync-write-watch!

(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (a-sync (lambda (await resume)
	    (a-sync-write-watch! resume out
				 (lambda (status)
				   (test-result 'out status)
				   (if (< count 3)
				       (begin
					 (set! count (1+ count))
					 (write-char #\a out)
					 (force-output out)
					 'more)
				       (begin
					 (write-char #\x out)
					 (force-output out)
					 (event-loop-remove-write-watch! out main-loop)
					 'done)))
				 main-loop)
	    (let loop ((res (await)))
	      (let ((ch (read-char in)))
		(if (not (char=? ch #\x))
		    (begin
		      (test-result 'more res)
		      (test-result #\a ch)
		      (loop (await)))
		    (test-result 'done res))))
	    (test-result 3 count)
	    (print-result)))
  (event-loop-run! main-loop))

;; Test 12: compose-a-sync and no-await

(compose-a-sync main-loop ((res (await-task-in-thread! (lambda ()
							 (+ 5 10)))))
	      ((no-await (test-result 15 res)
			 (print-result)
			 (event-loop-quit! main-loop))))
(event-loop-block! #t main-loop)
(event-loop-run! main-loop)

;;;;;;;;;; now the same tests with a default event loop ;;;;;;;;;;

(event-loop-block! #f main-loop)
(set-default-event-loop! main-loop)

;; Test 13: await-task!

(a-sync (lambda (await resume)
	  (let ((res
		 (await-task! await resume
			      (lambda ()
				(+ 5 10)))))
	    (test-result 15 res)
	    (print-result))))
(event-loop-run!)

;; Test 14: await-task-in-thread! without handler

;; set a new default event loop
(set-default-event-loop!)

(a-sync (lambda (await resume)
	  (let ((res
	  	 (await-task-in-thread! await resume
	  				(lambda ()
	  				  (+ 5 10)))))
	    (test-result 15 res)
	    (print-result)
	    (event-loop-quit!))))
(event-loop-block! #t)
(event-loop-run!)
(event-loop-block! #f)
  
;; Test 15: await-task-in-thread! without handler (explicit loop argument)

(a-sync (lambda (await resume)
	  (let ((res
	  	 (await-task-in-thread! await resume #f
	  				(lambda ()
	  				  (+ 5 10)))))
	    (test-result 15 res)
	    (print-result)
	    (event-loop-quit!))))
(event-loop-block! #t)
(event-loop-run!)
(event-loop-block! #f)
  
;; Test 16: await-task-in-thread! with handler

(a-sync (lambda (await resume)
	  (let ((res
	  	 (await-task-in-thread!
		  await resume
		  (lambda () (throw 'test-exception))
		  (lambda (key . args)
		    (test-result 'test-exception key)
		    5))))
	    (test-result 5 res)
	    (print-result)
	    (event-loop-quit!))))
(event-loop-block! #t)
(event-loop-run!)
(event-loop-block! #f)

;; Test 17: await-task-in-event-loop!

(let ()
  (define worker (make-event-loop 10 100000))

  (event-loop-block! #t)
  (event-loop-block! #t worker)

  (call-with-new-thread
   (lambda ()
     (event-loop-run! worker)))

  (a-sync (lambda (await resume)
	    (let ((res
		   (await-task-in-event-loop! await resume worker
					      (lambda ()
						(+ 5 10)))))
	      (test-result 15 res)
	      (print-result)
	      (event-loop-block! #f)
	      (event-loop-block! #f worker))))
  (event-loop-run!))

;; Test 18: await-timeout!

(a-sync (lambda (await resume)
	  (let ((res
		 (await-timeout! await resume 10
				 (lambda ()
				   (+ 5 10)))))
	    (test-result 15 res)
	    (print-result))))
(event-loop-run!)
  
;; Test 19: await-getline! (also tests a-sync-read-watch!)

(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (a-sync (lambda (await resume)
	    (let ((res (await-getline! await resume
				       in)))
	      (assert (string=? res "test-string"))
	      (print-result))))
  (write-line "test-string" out)
  (force-output out)
  (event-loop-run!))

;; Test 20: await-geteveryline! (also tests a-sync-read-watch!)

(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (a-sync (lambda (await resume)
	    (let ((res (await-geteveryline! await resume
					    in
					    (lambda (line)
					      (set! count (1+ count))
					      (when (= count 1)
						(assert (string=? line "test-string1")))
					      (when (= count 2)
					      	(assert (string=? line "test-string2"))
						(close out))))))
	      (assert (eof-object? res))
	      (test-result 2 count)
	      (print-result))))
  (write-line "test-string1" out)
  (write-line "test-string2" out)
  (force-output out)
  (event-loop-run!))

;; Test 21: await-getsomelines! (also tests a-sync-read-watch!)

(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (a-sync (lambda (await resume)
	    (let ((res (await-getsomelines! await resume
					    in
					    (lambda (line k)
					      (set! count (1+ count))
					      (when (= count 1)
						    (assert (string=? line "test-string1")))
					      (when (= count 2)
						    (assert (string=? line "test-string2")))
					      (when (= count 3)
						    (assert (string=? line "test-string3"))
						    (k 'exit-await))))))
	      (assert (eq? res 'exit-await))
	      (test-result 3 count)
	      (print-result))))
  (write-line "test-string1" out)
  (write-line "test-string2" out)
  (write-line "test-string3" out)
  (force-output out)
  (event-loop-run!)
  (close out))

;; Test 22: await-getsomelines! exception handling (also tests strategy for await-geteveryline!)
;; exception propagates out of event-loop-run!
(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (a-sync (lambda (await resume)
	    (await-getsomelines! await resume
				 in
				 (lambda (line k)
				   (set! count (1+ count))
				   (when (= count 1)
					 (assert (string=? line "test-string1")))
				   (when (= count 2)
					 (throw 'exit-exception))
				   (when (= count 3)
					 (assert #f)))) ;; we should never reach here
	    (assert #f))) ;; we should never reach here
  (write-line "test-string1" out)
  (write-line "test-string2" out)
  (write-line "test-string3" out)
  (force-output out)
  (catch #t
	 (lambda ()
	   (event-loop-run!)
	   (assert #f)) ;; we should never reach here
	 (lambda args
	   (assert (eq? (car args) 'exit-exception))))
  (close out)
  (test-result 2 count)
  (print-result))

;; Test 23: await-getsomelines! exception handling (also tests strategy for await-geteveryline!)
;; exception caught within a-sync block
(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (a-sync (lambda (await resume)
	    (catch #t
		   (lambda ()
		     (await-getsomelines! await resume
					  in
					  (lambda (line k)
					    (set! count (1+ count))
					    (when (= count 1)
						  (assert (string=? line "test-string1")))
					    (when (= count 2)
						  (throw 'exit-exception))
					    (when (= count 3)
						  (assert #f))))   ;; we should never reach here
		     (assert #f))   ;; we should never reach here
		   (lambda args
		     (assert (eq? (car args) 'exit-exception))))))
  (write-line "test-string1" out)
  (write-line "test-string2" out)
  (write-line "test-string3" out)
  (force-output out)
  (event-loop-run!)
  (close out)
  (test-result 2 count)
  (print-result))

;; Test 24: a-sync-write-watch!

(let ()
  (define test-pipe (pipe))
  (define in (car test-pipe))
  (define out (cdr test-pipe))
  (define count 0)
  (a-sync (lambda (await resume)
	    (a-sync-write-watch! resume out
				 (lambda (status)
				   (test-result 'out status)
				   (if (< count 3)
				       (begin
					 (set! count (1+ count))
					 (write-char #\a out)
					 (force-output out)
					 'more)
				       (begin
					 (write-char #\x out)
					 (force-output out)
					 (event-loop-remove-write-watch! out)
					 'done))))
	    (let loop ((res (await)))
	      (let ((ch (read-char in)))
		(if (not (char=? ch #\x))
		    (begin
		      (test-result 'more res)
		      (test-result #\a ch)
		      (loop (await)))
		    (test-result 'done res))))
	    (test-result 3 count)
	    (print-result)))
  (event-loop-run!))

;; Test 25: compose-a-sync and no-await

(compose-a-sync ((res (await-task-in-thread! (lambda ()
					       (+ 5 10)))))
	      ((no-await (test-result 15 res)
			 (print-result)
			 (event-loop-quit!))))
(event-loop-block! #t)
(event-loop-run!)
