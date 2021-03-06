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

(use-modules (a-sync coroutines)
	     (a-sync event-loop)
	     (a-sync meeting)
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

;; Test 1: start receiving before sending, iteratively on single meeting object

(define main-loop (make-event-loop))

(let ()
  (define m1 (make-meeting main-loop))
  (define res '())

  (a-sync (lambda (await resume)
	    (let next ((datum (meeting-receive await resume main-loop m1)))
	      (when (not (eq? datum 'stop-iteration))
		(set! res (cons datum res))
		(next (meeting-receive await resume main-loop m1))))))

  (a-sync (lambda (await resume)
	    (let next ((count 0))
	      (if (< count 4)
		  (begin
		    (meeting-send await resume main-loop m1 count)
		    (next (1+ count)))
		  (meeting-close m1)))))

  (event-loop-run! main-loop)
  (assert (equal? res '(3 2 1 0)))
  (print-result))

;; Test 2: start sending before receiving, iteratively on single meeting object

(let ()
  (define m1 (make-meeting main-loop))
  (define res '())

  (a-sync (lambda (await resume)
	    (let next ((count 0))
	      (if (< count 4)
		  (begin
		    (meeting-send await resume main-loop m1 count)
		    (next (1+ count)))
		  (meeting-close m1)))))

  (a-sync (lambda (await resume)
	    (let next ((datum (meeting-receive await resume main-loop m1)))
	      (when (not (eq? datum 'stop-iteration))
		(set! res (cons datum res))
		(next (meeting-receive await resume main-loop m1))))))

  (event-loop-run! main-loop)
  (assert (equal? res '(3 2 1 0)))
  (print-result))

;;;;;;;;;; now the same tests with a default event loop ;;;;;;;;;;

(set-default-event-loop! main-loop)

;; Test 3: start receiving before sending, iteratively on single meeting object

(let ()
  (define m1 (make-meeting))
  (define res '())

  (a-sync (lambda (await resume)
	    (let next ((datum (meeting-receive await resume m1)))
	      (when (not (eq? datum 'stop-iteration))
		(set! res (cons datum res))
		(next (meeting-receive await resume m1))))))

  (a-sync (lambda (await resume)
	    (let next ((count 0))
	      (if (< count 4)
		  (begin
		    (meeting-send await resume m1 count)
		    (next (1+ count)))
		  (meeting-close m1)))))

  (event-loop-run!)
  (assert (equal? res '(3 2 1 0)))
  (print-result))

;; Test 4: start sending before receiving, iteratively on single meeting object

(let ()
  (define m1 (make-meeting))
  (define res '())

  (a-sync (lambda (await resume)
	    (let next ((count 0))
	      (if (< count 4)
		  (begin
		    (meeting-send await resume m1 count)
		    (next (1+ count)))
		  (meeting-close m1)))))

  (a-sync (lambda (await resume)
	    (let next ((datum (meeting-receive await resume m1)))
	      (when (not (eq? datum 'stop-iteration))
		(set! res (cons datum res))
		(next (meeting-receive await resume m1))))))

  (event-loop-run!)
  (assert (equal? res '(3 2 1 0)))
  (print-result))

;;;;;;;;;;;;;;;;;; additional tests ;;;;;;;;;;;;;;;;;;

;; Test 5: meeting-ready?

(let ()
  (define m1 (make-meeting))

  (a-sync (lambda (await resume)
	    (assert (not (meeting-ready? m1)))
	    (meeting-send await resume m1 0)))

  (a-sync (lambda (await resume)
	    (assert (meeting-ready? m1))
	    (meeting-receive await resume m1)
	    (assert (not (meeting-ready? m1)))
	    (meeting-close m1)
	    (assert (meeting-ready? m1))
	    (print-result)))
  (event-loop-run!))

;; Test 6: multiple readers on single meeting object (fan out)

(let ()
  (define m1 (make-meeting))

  (a-sync (lambda (await resume)
	    (test-result (meeting-receive await resume m1) 0)))

  (a-sync (lambda (await resume)
	    (test-result (meeting-receive await resume m1) 1)))

  (a-sync (lambda (await resume)
	    (test-result (meeting-receive await resume m1) 2)))

  (a-sync (lambda (await resume)
	    (test-result (meeting-receive await resume m1) 'stop-iteration)))

  (a-sync (lambda (await resume)
	    (test-result (meeting-receive await resume m1) 'stop-iteration)))

  (a-sync (lambda (await resume)
	    (let next ((count 0))
	      (if (< count 3)
		  (begin
		    (meeting-send await resume m1 count)
		    (next (1+ count)))
		  (meeting-close m1)))))

  (a-sync (lambda (await resume)
  	    (test-result (meeting-receive await resume m1) 'stop-iteration)))

  (event-loop-run!)
  (print-result))

;; Test 7: multiple senders on single meeting object (fan in)

(let ()
  (define m1 (make-meeting))

  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m1 0) #f)))

  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m1 1) #f)))

  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m1 2) #f)))

  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m1 3) 'stop-iteration)))

  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m1 4) 'stop-iteration)))

  (a-sync (lambda (await resume)
	    (let next ((count 0))
	      (if (< count 3)
		  (let ((datum (meeting-receive await resume m1)))
		    (test-result datum count)
		    (next (1+ count)))
		  (meeting-close m1)))))
  
  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m1 5) 'stop-iteration)))

  (event-loop-run!)
  (print-result))

;; Test 8: waiting to receive from multiple meeting objects (1)

(let ()
  (define m1 (make-meeting))
  (define m2 (make-meeting))
  (define m3 (make-meeting))
  (define m4 (make-meeting))

  (a-sync (lambda (await resume)
	    (let next ((count 1))
	      (when (< count 4)
		(test-result (meeting-receive await resume m1 m2 m3 m4) count)
		(next (1+ count))))))

  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m1 1) #f)))
  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m2 2) #f)))
  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m3 3) #f)))

  (event-loop-run!)
  (print-result))

;; Test 9: waiting to receive from multiple meeting objects (2)

(let ()
  (define m1 (make-meeting))
  (define m2 (make-meeting))
  (define m3 (make-meeting))
  (define m4 (make-meeting))

  (a-sync (lambda (await resume)
	    (let next ((count 1))
	      (when (< count 4)
		(test-result (meeting-receive await resume m1 m2 m3 m4) count)
		(next (1+ count))))))

  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m1 1) #f)
	    (test-result (meeting-send await resume m2 2) #f)
	    (test-result (meeting-send await resume m3 3) #f)))

  (event-loop-run!)
  (print-result))

;; Test 10: waiting to receive from multiple meeting objects (3)

(let ()
  (define m1 (make-meeting))
  (define m2 (make-meeting))
  (define m3 (make-meeting))
  (define m4 (make-meeting))

  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m1 1) #f)))
  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m2 2) #f)))
  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m3 3) #f)))

  (a-sync (lambda (await resume)
	    (let next ((count 1))
	      (when (< count 4)
		(test-result (meeting-receive await resume m1 m2 m3 m4) count)
		(next (1+ count))))))

  (event-loop-run!)
  (print-result))

;; Test 11: waiting to receive from multiple meeting objects (4)

(let ()
  (define m1 (make-meeting))
  (define m2 (make-meeting))
  (define m3 (make-meeting))
  (define m4 (make-meeting))

  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m1 1) #f)
	    (test-result (meeting-send await resume m2 2) #f)
	    (test-result (meeting-send await resume m3 3) #f)))

  (a-sync (lambda (await resume)
	    (let next ((count 1))
	      (when (< count 4)
		(test-result (meeting-receive await resume m1 m2 m3 m4) count)
		(next (1+ count))))))

  (event-loop-run!)
  (print-result))

;; Test 12: waiting to send to multiple meeting objects (1)

(let ()
  (define m1 (make-meeting))
  (define m2 (make-meeting))

  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m1 m2 1) #f)
	    (test-result (meeting-send await resume m1 m2 2) #f)
	    (test-result (meeting-send await resume m1 m2 3) #f)
	    (test-result (meeting-send await resume m1 m2 4) #f)))

  (a-sync (lambda (await resume)
	    (test-result (meeting-receive await resume m2) 1)))
  (a-sync (lambda (await resume)
	    (test-result (meeting-receive await resume m1) 2)))
  (a-sync (lambda (await resume)
	    (test-result (meeting-receive await resume m2) 3)))

  (event-loop-run!)
  (print-result))

;; Test 13: waiting to send to multiple meeting objects (2)

(let ()
  (define m1 (make-meeting))
  (define m2 (make-meeting))

  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m1 m2 1) #f)
	    (test-result (meeting-send await resume m1 m2 2) #f)
	    (test-result (meeting-send await resume m1 m2 3) #f)
	    (test-result (meeting-send await resume m1 m2 4) #f)))

  (a-sync (lambda (await resume)
	    (test-result (meeting-receive await resume m2) 1)
  	    (test-result (meeting-receive await resume m1) 2)
  	    (test-result (meeting-receive await resume m2) 3)
  	    (test-result (meeting-receive await resume m1) 4)))

  (event-loop-run!)
  (print-result))

;; Test 14: waiting to send to multiple meeting objects (3)

(let ()
  (define m1 (make-meeting))
  (define m2 (make-meeting))

  (a-sync (lambda (await resume)
	    (test-result (meeting-receive await resume m2) 2)))
  (a-sync (lambda (await resume)
	    (test-result (meeting-receive await resume m1) 1)))
  (a-sync (lambda (await resume)
	    (test-result (meeting-receive await resume m2) 3)))

  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m1 m2 1) #f)
	    (test-result (meeting-send await resume m1 m2 2) #f)
	    (test-result (meeting-send await resume m1 m2 3) #f)
	    (test-result (meeting-send await resume m1 m2 4) #f)))

  (event-loop-run!)
  (print-result))

;; Test 15: waiting to send to multiple meeting objects (4)

(let ()
  (define m1 (make-meeting))
  (define m2 (make-meeting))

  (a-sync (lambda (await resume)
	    (test-result (meeting-receive await resume m2) 1)
  	    (test-result (meeting-receive await resume m1) 2)
  	    (test-result (meeting-receive await resume m2) 3)
  	    (test-result (meeting-receive await resume m1) 4)))

  (a-sync (lambda (await resume)
	    (test-result (meeting-send await resume m1 m2 1) #f)
	    (test-result (meeting-send await resume m1 m2 2) #f)
	    (test-result (meeting-send await resume m1 m2 3) #f)
	    (test-result (meeting-send await resume m1 m2 4) #f)))

  (event-loop-run!)
  (print-result))
