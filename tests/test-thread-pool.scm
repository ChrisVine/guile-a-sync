;; Copyright (C) 2017 Chris Vine

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

(use-modules (a-sync thread-pool)
	     (a-sync coroutines)
	     (a-sync event-loop)
	     (ice-9 threads)  ;; for mutexes and condition variables
             (rnrs base))     ;; for assert

;; helpers

(define-syntax-rule (test-result expected res)
  (assert (eqv? expected res)))

(define print-result
  ((lambda ()
     (define count 1)
     (lambda ()
       (simple-format #t "~A: Test ~A OK\n" (basename (current-filename)) count)
       (set! count (1+ count))))))

;; Test 1: default settings

(let ((pool (make-thread-pool)))
  (test-result 0 (thread-pool-get-num-tasks pool))
  (test-result 0 (thread-pool-get-num-threads pool))
  (test-result 8 (thread-pool-get-max-threads pool))
  (test-result #f (thread-pool-get-non-blocking pool))
  (test-result 5000 (thread-pool-get-idle-time pool))
  (thread-pool-stop! pool)
  (print-result))

;; Test 2: supplied settings

(let ((pool (make-thread-pool #:max-threads 6 #:min-threads 4 #:idle 1000 #:non-blocking #t)))
  (test-result 0 (thread-pool-get-num-tasks pool))
  (test-result 4 (thread-pool-get-num-threads pool))
  (test-result 6 (thread-pool-get-max-threads pool))
  (test-result #t (thread-pool-get-non-blocking pool))
  (test-result 1000 (thread-pool-get-idle-time pool))

  (thread-pool-change-max-threads! pool -1)
  (thread-pool-set-non-blocking! pool #f)
  (thread-pool-set-idle-time! pool 10000)
  (test-result 5 (thread-pool-get-max-threads pool))
  (test-result #f (thread-pool-get-non-blocking pool))
  (test-result 10000 (thread-pool-get-idle-time pool))

  (thread-pool-change-max-threads! pool 3)
  (test-result 8 (thread-pool-get-max-threads pool))

  (thread-pool-stop! pool)
  (print-result))

;; Test 3: thread-pool-add! without fail handler

(let ((pool (make-thread-pool #:max-threads 3 #:min-threads 1))
      (mutex (make-mutex))
      (condvar (make-condition-variable))
      (count 0))
  (test-result 1 (thread-pool-get-num-threads pool))
  (thread-pool-add! pool (lambda ()
			   (usleep 100000) ;; so we know all 3 threads will start
			   (with-mutex mutex
			     (set! count (1+ count))
			     (signal-condition-variable condvar))))
  (thread-pool-add! pool (lambda ()
			   (usleep 100000) ;; so we know all 3 threads will start
			   (with-mutex mutex
			     (set! count (1+ count)))
			   (signal-condition-variable condvar)))
  (thread-pool-add! pool (lambda ()
			   (usleep 100000) ;; so we know all 3 threads will start
			   (with-mutex mutex
			     (set! count (1+ count))
			     (signal-condition-variable condvar))))
  (thread-pool-add! pool (lambda ()
			   (with-mutex mutex
			     (set! count (1+ count))
			     (signal-condition-variable condvar))))
  (thread-pool-add! pool (lambda ()
			   (with-mutex mutex
			     (set! count (1+ count))
			     (signal-condition-variable condvar))))
  (test-result 5 (thread-pool-get-num-tasks pool))
  (test-result 3 (thread-pool-get-num-threads pool))
  (with-mutex mutex
    (do ()
	((= count 5))
      (wait-condition-variable condvar mutex)))
  (test-result 5 count)
  (test-result 3 (thread-pool-get-num-threads pool))
  (usleep 50000) ;; give enough time for the pool threads to reset
		 ;; num-tasks when each task returns before we test
		 ;; this
  (test-result 0 (thread-pool-get-num-tasks pool))
  (thread-pool-stop! pool)
  (print-result))

;; Test 4: thread-pool-add! with fail handler

(let ((pool (make-thread-pool #:max-threads 3 #:min-threads 0))
      (mutex (make-mutex))
      (condvar (make-condition-variable))
      (count 0))
  (test-result 0 (thread-pool-get-num-threads pool))
  (thread-pool-add! pool
		    (lambda ()
		      (usleep 100000) ;; so we know all 3 threads will start
		      (with-mutex mutex
			(set! count (1+ count))
			(signal-condition-variable condvar)))
		    (lambda args
		      (assert #f))) ;; we should never reach here
  (thread-pool-add! pool
		    (lambda ()
		      (usleep 100000) ;; so we know all 3 threads will start
		      (with-mutex mutex
			(set! count (1+ count))
			(signal-condition-variable condvar)))
		    (lambda args
		      (assert #f))) ;; we should never reach here
  (thread-pool-add! pool
		    (lambda ()
		      (usleep 100000) ;; so we know all 3 threads will start
		      (with-mutex mutex
			(set! count (1+ count))
			(signal-condition-variable condvar)))
		    (lambda args
		      (assert #f))) ;; we should never reach here
  (thread-pool-add! pool
		    (lambda ()
		      (with-mutex mutex
			(set! count (1+ count))
			(signal-condition-variable condvar)))
		    (lambda args
		      (assert #f))) ;; we should never reach here
  (thread-pool-add! pool
		    (lambda ()
		      (with-mutex mutex
			(set! count (1+ count))
			(signal-condition-variable condvar)))
		    (lambda args
		      (assert #f))) ;; we should never reach here
  (test-result 5 (thread-pool-get-num-tasks pool))
  (test-result 3 (thread-pool-get-num-threads pool))
  (with-mutex mutex
    (do ()
	((= count 5))
      (wait-condition-variable condvar mutex)))
  (test-result 5 count)
  (test-result 3 (thread-pool-get-num-threads pool))
  (thread-pool-stop! pool)
  (print-result))

;; Test 5: thread-pool-add! with throwing task

(let ((pool (make-thread-pool))
      (mutex (make-mutex))
      (condvar (make-condition-variable))
      (count 0))
  (thread-pool-add! pool
		    (lambda ()
		      (with-mutex mutex
			(set! count (1+ count))
			(signal-condition-variable condvar)))
		    (lambda args
		      (assert #f))) ;; we should never reach here
  (thread-pool-add! pool
		    (lambda ()
		      (throw 'quelle-horreur)
		      (assert #f))  ;; we should never reach here
		    (lambda (key)
		      (test-result 'quelle-horreur key)
		      (with-mutex mutex
			(set! count (1+ count))
			(signal-condition-variable condvar))))
  (with-mutex mutex
    (do ()
	((= count 2))
      (wait-condition-variable condvar mutex)))
  (test-result 2 count)
  (thread-pool-stop! pool)
  (print-result))

;; Test 6: thread-pool-stop! with queued tasks (blocking)

(let ((pool (make-thread-pool #:non-blocking #f))
      (mutex (make-mutex))
      (count 0))
  (thread-pool-add! pool (lambda ()
			   (usleep 50000)
			   (with-mutex mutex
			     (set! count (1+ count)))))
  (thread-pool-add! pool (lambda ()
			   (usleep 50000)
			   (with-mutex mutex
			     (set! count (1+ count)))))
  (thread-pool-add! pool (lambda ()
			   (usleep 50000)
			   (with-mutex mutex
			     (set! count (1+ count)))))
  (thread-pool-add! pool (lambda ()
			   (usleep 50000)
			   (with-mutex mutex
			     (set! count (1+ count)))))
  (thread-pool-stop! pool)
  (test-result 4 count)
  (print-result))

;; Test 7: thread-pool-stop! with queued tasks (non-blocking)

(let ((pool (make-thread-pool #:non-blocking #t))
      (mutex (make-mutex))
      (condvar (make-condition-variable))
      (count 0))
  (thread-pool-add! pool (lambda ()
			   (usleep 100000) ;; so when first tested, count is 0
			   (with-mutex mutex
			     (set! count (1+ count))
			     (signal-condition-variable condvar))))
  (thread-pool-add! pool (lambda ()
			   (usleep 100000) ;; so when first tested, count is 0
			   (with-mutex mutex
			     (set! count (1+ count))
			     (signal-condition-variable condvar))))
  (thread-pool-add! pool (lambda ()
			   (usleep 100000) ;; so when first tested, count is 0
			   (with-mutex mutex
			     (set! count (1+ count))
			     (signal-condition-variable condvar))))
  (thread-pool-add! pool (lambda ()
			   (usleep 100000) ;; so when first tested, count is 0
			   (with-mutex mutex
			     (set! count (1+ count))
			     (signal-condition-variable condvar))))
  (thread-pool-stop! pool)
  (test-result 0 count)
  (with-mutex mutex
    (do ()
	((= count 4))
      (wait-condition-variable condvar mutex)))
  (test-result 4 count)
  (print-result))

;; Test 8: await-task-in-thread! without handler

(define main-loop (make-event-loop))

(let ((pool (make-thread-pool)))
  (a-sync (lambda (await resume)
	    (let ((res
		   (await-task-in-thread-pool! await resume main-loop pool
					       (lambda ()
						 (+ 5 10)))))
	      (test-result 15 res)
	      (test-result 0 (thread-pool-get-num-tasks pool))
	      (test-result 1 (thread-pool-get-num-threads pool))
	      (print-result)
	      (event-loop-quit! main-loop))))
  (event-loop-block! #t main-loop)
  (event-loop-run! main-loop)
  (event-loop-block! #f main-loop)
  (thread-pool-stop! pool))
		    
;; Test 9: await-task-in-thread! with handler

(let ((pool (make-thread-pool)))
  (a-sync (lambda (await resume)
	    (let ((res
		   (await-task-in-thread-pool!
		    await resume main-loop pool
		    (lambda () (throw 'test-exception))
		    (lambda (key . args)
		      (test-result 'test-exception key)
		      5))))
	      (test-result 5 res)
	      (test-result 0 (thread-pool-get-num-tasks pool))
	      (test-result 1 (thread-pool-get-num-threads pool))
	      (print-result)
	      (event-loop-quit! main-loop))))
  (event-loop-block! #t main-loop)
  (event-loop-run! main-loop)
  (event-loop-block! #f main-loop)
  (thread-pool-stop! pool))

;; Test 10: await-generator-in-thread-pool! without handler

(let ((pool (make-thread-pool))
      (lst '()))
  (a-sync (lambda (await resume)
	    (let ((res
		   (await-generator-in-thread-pool! await resume main-loop pool
						    (lambda (yield)
						      (let loop ((count 0))
							(when (< count 5)
							  (yield (* 2 count))
							  (loop (1+ count)))))
						    (lambda (val)
						      (set! lst (cons val lst))))))
	      (test-result (car lst) 8)
	      (test-result (length lst) 5)
	      (test-result res #f)
	      (test-result 0 (thread-pool-get-num-tasks pool))
	      (test-result 1 (thread-pool-get-num-threads pool))
	      (print-result)
	      (event-loop-block! #f main-loop))))
  (event-loop-block! #t main-loop)
  (event-loop-run! main-loop)
  (thread-pool-stop! pool))

;; Test 11: await-generator-in-thread-pool! with handler

(let ((pool (make-thread-pool))
      (lst '()))
  (a-sync (lambda (await resume)
	    (let ((res
		   (await-generator-in-thread-pool! await resume main-loop pool
						    (lambda (yield)
						      (let loop ((count 0))
							(cond
							 ((< count 5)
							  (yield (* 2 count))
							  (loop (1+ count)))
							 ((= count 5)
							  (throw 'my-exception)
							  ;; we never reach here
							  (yield (* 2 count))
							  (loop (1+ count)))
							 (else
							  (assert #f))))) ;; we should never reach here
						    (lambda (val)
						      (set! lst (cons val lst)))
						    (lambda args
						      (test-result (length args) 1)
						      (test-result (car args) 'my-exception)
						      (set! lst (cons 100 lst))))))
	      (test-result (car lst) 100)
	      (test-result (length lst) 6)
	      (test-result res 'guile-a-sync-thread-error)
	      (test-result 0 (thread-pool-get-num-tasks pool))
	      (test-result 1 (thread-pool-get-num-threads pool))
	      (print-result)
	      (event-loop-block! #f main-loop))))
  (event-loop-block! #t main-loop)
  (event-loop-run! main-loop)
  (thread-pool-stop! pool))

;;;;;;;;;; now the same await tests with a default event loop ;;;;;;;;;;

(event-loop-block! #f main-loop)
(set-default-event-loop! main-loop)

;; Test 12: await-task-in-thread! without handler

(let ((pool (make-thread-pool)))
  (a-sync (lambda (await resume)
	    (let ((res
		   (await-task-in-thread-pool! await resume pool
					       (lambda ()
						 (+ 5 10)))))
	      (test-result 15 res)
	      (test-result 0 (thread-pool-get-num-tasks pool))
	      (test-result 1 (thread-pool-get-num-threads pool))
	      (print-result)
	      (event-loop-quit!))))
  (event-loop-block! #t)
  (event-loop-run!)
  (event-loop-block! #f)
  (thread-pool-stop! pool))
		    
;; Test 13: await-task-in-thread! with handler

(let ((pool (make-thread-pool)))
  (a-sync (lambda (await resume)
	    (let ((res
		   (await-task-in-thread-pool!
		    await resume pool
		    (lambda () (throw 'test-exception))
		    (lambda (key . args)
		      (test-result 'test-exception key)
		      5))))
	      (test-result 5 res)
	      (test-result 0 (thread-pool-get-num-tasks pool))
	      (test-result 1 (thread-pool-get-num-threads pool))
	      (print-result)
	      (event-loop-quit!))))
  (event-loop-block! #t)
  (event-loop-run!)
  (event-loop-block! #f)
  (thread-pool-stop! pool))

;; Test 14: await-generator-in-thread-pool! without handler

(let ((pool (make-thread-pool))
      (lst '()))
  (a-sync (lambda (await resume)
	    (let ((res
		   (await-generator-in-thread-pool! await resume pool
						    (lambda (yield)
						      (let loop ((count 0))
							(when (< count 5)
							  (yield (* 2 count))
							  (loop (1+ count)))))
						    (lambda (val)
						      (set! lst (cons val lst))))))
	      (test-result (car lst) 8)
	      (test-result (length lst) 5)
	      (test-result res #f)
	      (test-result 0 (thread-pool-get-num-tasks pool))
	      (test-result 1 (thread-pool-get-num-threads pool))
	      (print-result)
	      (event-loop-block! #f))))
  (event-loop-block! #t)
  (event-loop-run!)
  (thread-pool-stop! pool))

;; Test 15: await-generator-in-thread-pool! with handler

(let ((pool (make-thread-pool))
      (lst '()))
  (a-sync (lambda (await resume)
	    (let ((res
		   (await-generator-in-thread-pool! await resume pool
						    (lambda (yield)
						      (let loop ((count 0))
							(cond
							 ((< count 5)
							  (yield (* 2 count))
							  (loop (1+ count)))
							 ((= count 5)
							  (throw 'my-exception)
							  ;; we never reach here
							  (yield (* 2 count))
							  (loop (1+ count)))
							 (else
							  (assert #f))))) ;; we should never reach here
						    (lambda (val)
						      (set! lst (cons val lst)))
						    (lambda args
						      (test-result (length args) 1)
						      (test-result (car args) 'my-exception)
						      (set! lst (cons 100 lst))))))
	      (test-result (car lst) 100)
	      (test-result (length lst) 6)
	      (test-result res 'guile-a-sync-thread-error)
	      (test-result 0 (thread-pool-get-num-tasks pool))
	      (test-result 1 (thread-pool-get-num-threads pool))
	      (print-result)
	      (event-loop-block! #f))))
  (event-loop-block! #t)
  (event-loop-run!)
  (thread-pool-stop! pool))
