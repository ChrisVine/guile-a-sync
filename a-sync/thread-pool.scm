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

(define-module (a-sync thread-pool)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 q)           ;; for make-q, etc
  #:use-module (ice-9 control)     ;; for call/ec
  #:use-module (ice-9 threads)     ;; for call-with-new-thread, mutexes and condition variables
  #:use-module (ice-9 match)
  #:use-module (a-sync coroutines) ;; for make-iterator
  #:use-module (a-sync event-loop) ;; for event-post!
  #:export (make-thread-pool
	    thread-pool?
	    thread-pool-get-num-tasks
	    thread-pool-get-num-threads
	    thread-pool-get-max-threads
	    thread-pool-change-max-threads!
	    thread-pool-get-non-blocking
	    thread-pool-set-non-blocking!
	    thread-pool-get-idle-time
	    thread-pool-set-idle-time!
	    thread-pool-stop!
	    thread-pool-add!
	    with-thread-pool-increment
	    await-task-in-thread-pool!
	    await-generator-in-thread-pool!))


(define-record-type <a-queue>
  (_make-a-queue mutex condvar q)
  a-queue?
  (mutex aq-mutex-get)
  (condvar aq-condvar-get)
  (q q-get))
   
(define (make-a-queue)
  (_make-a-queue (make-mutex)
		 (make-condition-variable)
		 (make-q)))

(define (a-queue-pop! aq)
  (let ((mutex (aq-mutex-get aq)))
    (with-mutex mutex
      (let ((q (q-get aq)))
        (let lp ()
          (if (q-empty? q)
              (begin
                (wait-condition-variable (aq-condvar-get aq) mutex)
                (lp))
	      (deq! q)))))))

(define (get-abs-time msecs)
  (let ((ms (inexact->exact (round msecs))))
    (when (< ms 0)
      (error "Negative msecs argument for get-abs-time"))
    (let* ((curtime (gettimeofday))
	   ;; let's keep the calculation within the fixnum range by
	   ;; taking an initial remainder of msecs
	   (usecs-tmp (+ (cdr curtime) (* (remainder ms 1000) 1000))))
      (cons (+ (car curtime) (quotient ms 1000) (quotient usecs-tmp 1000000))
	    (remainder usecs-tmp 1000000)))))

(define (a-queue-timed-pop! aq msecs)
  (let ((mutex (aq-mutex-get aq)))
    (with-mutex mutex
      (let ((q (q-get aq)))
        (let lp ()
          (if (q-empty? q)
              (if (wait-condition-variable (aq-condvar-get aq) mutex (get-abs-time msecs))
		  (lp)
		  'timeout)
	      (deq! q)))))))

(define (a-queue-push! aq item)
  (with-mutex (aq-mutex-get aq)
    (enq! (q-get aq) item))
  (signal-condition-variable (aq-condvar-get aq)))


(define-record-type <thread-pool>
  (_make-thread-pool mutex condvar aq max-threads min-threads num-threads
		     idle-time num-tasks blocking stopped)
  thread-pool?
  (mutex mutex-get)
  (condvar condvar-get)
  (aq aq-get)
  (max-threads max-threads-get max-threads-set!)
  (min-threads min-threads-get)
  (num-threads num-threads-get num-threads-set!)
  (idle-time idle-time-get idle-time-set!)
  (num-tasks num-tasks-get num-tasks-set!)
  (blocking blocking-get blocking-set!)
  (stopped stopped-get stopped-set!))

;; This procedure constructs a thread pool object of native OS
;; threads.  It takes four optional arguments.  The #:max-thread
;; keyname specifies the maximum number of threads which will run in
;; the pool, and the default value is 8.  The #:min-threads keyname
;; specifies the minimum number of persistent threads which will run
;; in the pool and will not be subject to an #:idle timeout, and the
;; default value is 0.  It is an error if #:min-threads is greater
;; than #:max-threads.
;;
;; Thread pool objects with a #:min-threads setting of greater than 0
;; are usually best kept as top level objects, because the minimum
;; value of threads will keep alive in the pool until
;; thread-pool-stop! is called.  If such a thread pool is constructed
;; within a local lexical scope, then either thread-pool-stop! must be
;; applied to the pool before that scope is exited, or the last task
;; added to the pool should itself apply thread-pool-stop! to the pool
;; (which it can do if 'non-blocking' is #t).  Otherwise, the minimum
;; value of threads will remain alive uselessly in blocked condition
;; in the pool until the program terminates, even though the pool may
;; be inaccessible.
;;
;; The #:idle keyname specifies the length of time in milliseconds
;; that threads greater in number than #:min-threads and not executing
;; any tasks will remain in existence.  The default is 5000 (5
;; seconds).
;;
;; The #:non-blocking keyname affects the operation of the
;; thread-pool-stop! procedure.  When set to #f, which is the default,
;; that procedure will not return until all tasks previously added to
;; the pool have completed.  If set to #t, the thread-pool-stop!
;; procedure will return immediately, before all tasks have finished.
;;
;; The #:max-threads, #:non-blocking and #:idle settings may
;; subsequently be altered by applying the
;; thread-pool-change-max-threads!, thread-pool-set-non-blocking! or
;; thread-pool-set-idle-time! procedure to the pool.
;;
;; This procedure will throw an exception if the system is unable to
;; start the number of threads given as the #:min-threads argument.
;; In such a case, any threads which have in fact started in the pool
;; will be killed.
;;
;; This procedure is first available in version 0.18 of this library.
(define* (make-thread-pool #:key max-threads min-threads idle non-blocking)
  (when (and max-threads
	     (< max-threads 1))
    (error "max-threads value passed to make-thread-pool is less than 1"))
  (when (and min-threads
	     (negative? min-threads))
    (error "min-threads value passed to make-thread-pool is negative"))
  (when (and min-threads
	     (or (and max-threads
		      (> min-threads max-threads))
		 (and (not max-threads)
		      (> min-threads 8))))
    (error "min-threads value passed to make-thread-pool is greater than max-threads value"))
  (let ((pool (_make-thread-pool (make-mutex)
				 (make-condition-variable)
				 (make-a-queue)
				 (or max-threads 8)
				 (or min-threads 0)
				 0
				 (or idle 5000)
				 0
				 (not non-blocking)
				 #f)))
    (catch #t
      (lambda ()
	(when min-threads
	  (do ((count 0 (1+ count)))
	      ((= count min-threads))
	    (call-with-new-thread (lambda () (thread-loop pool #t)))
	    (num-threads-set! pool (1+ (num-threads-get pool))))))
      ;; if starting any new threads failed, kill them all before
      ;; rethrowing the exception
      (lambda args
	(let ((thread-count (num-threads-get pool)))
	  (do ((kill-count 0 (1+ kill-count)))
	      ((= kill-count thread-count))
	    (a-queue-push! (aq-get pool) (cons (lambda () (throw 'kill-thread)) #f)))
	  (apply throw args))))
    pool))

;; This is the thread loop which each thread will execute, taking
;; tasks from the task queue as they become available.  If
;; 'persistent' is true, the thread will keep running until
;; event-loop-stop! is called irrespective of the thread pool's idle
;; value.
(define (thread-loop pool persistent)
  (call/ec
   (lambda (return)
     (let ((mutex (mutex-get pool)))
       (let lp ((task (if persistent
			  (a-queue-pop! (aq-get pool))
			  (a-queue-timed-pop! (aq-get pool) (idle-time-get pool)))))
	 (if (eq? task 'timeout)
	     (begin
	       (with-mutex mutex
		 ;; test in case between aq unblocking and the mutex
		 ;; being acquired, add-task has added a task
		 ;; expecting to find this waiting thread
		 (if (< (num-tasks-get pool) (num-threads-get pool))
		     (begin
		       (num-threads-set! pool (1- (num-threads-get pool)))
		       (when (and (stopped-get pool)
				  (blocking-get pool))
			 (broadcast-condition-variable (condvar-get pool)))
		       ;; end thread if idle time elapsed without a task
		       (return #f))
		     (lp (if persistent
			     (a-queue-pop! (aq-get pool))
			     (a-queue-timed-pop! (aq-get pool) (idle-time-get pool)))))))
	     (begin
	      (catch #t
		(lambda ()
		  ((car task)))
		(lambda (key . args)
		  (if (eq? key 'kill-thread)
		      ;; we don't decrement 'tasks' here, as adding a
		      ;; 'kill-thread callback does not increment the
		      ;; number of tasks
		      (with-mutex mutex
			(num-threads-set! pool (1- (num-threads-get pool)))
			(when (and (stopped-get pool)
				   (blocking-get pool))
			  (broadcast-condition-variable (condvar-get pool)))
			(return #f))
		      (let ((fail-handler (cdr task)))
			(if fail-handler
			    (apply fail-handler key args)
			    (error
			     (string-append "Exception thrown by thread pool task with no fail-handler: "
					    (object->string (cons key args)))))))))
	      (with-mutex mutex
		(num-tasks-set! pool (1- (num-tasks-get pool)))
		;; cater for a case where the maximum number of
		;; threads has been reduced by the user
		(when (and (not persistent)
			   (> (num-threads-get pool) (max-threads-get pool)))
		  (num-threads-set! pool (1- (num-threads-get pool)))
		  (when (and (stopped-get pool)
			     (blocking-get pool))
		    (broadcast-condition-variable (condvar-get pool)))
		  (return #f)))
	      ;; we are outside the mutex here
	      (lp (if persistent
		      (a-queue-pop! (aq-get pool))
		      (a-queue-timed-pop! (aq-get pool) (idle-time-get pool)))))))))))

;; This procedure returns the number of tasks which the thread pool
;; object is at present either running in the pool or has queued for
;; execution.  This procedure will not throw.  It is also thread safe,
;; although it accesses the task number field outside the pool mutex
;; and therefore with relaxed memory ordering.  That enables this
;; procedure to be applied more efficiently for rate limiting purposes
;; but the result might at any one time be marginally out of date.
;;
;; This procedure is first available in version 0.18 of this library.
(define (thread-pool-get-num-tasks pool)
  ;; we do not use the thread pool mutex to protect the num-tasks
  ;; record field here for efficiency reasons, as user code may want
  ;; to call it for rate-limiting reasons.  The field could therefore
  ;; be modified by another thread concurrently with this read, but
  ;; guile guarantees that storing into a SCM location concurrently
  ;; from multiple threads is thread safe.  This gives us an
  ;; equivalent to relaxed (unsynchronized) atomic memory ordering,
  ;; which is sufficient for our purpose.
  (num-tasks-get pool))

;; This procedure returns the number of threads currently running in
;; the thread pool.
;;
;; This procedure is thread safe (any thread may call it).
;;
;; This procedure is first available in version 0.18 of this library.
(define (thread-pool-get-num-threads pool)
  (with-mutex (mutex-get pool)
    (num-threads-get pool)))

;; This procedure returns the current maximum number of threads set
;; for the thread pool.
;;
;; This procedure is thread safe (any thread may call it).
;;
;; This procedure is first available in version 0.18 of this library.
(define (thread-pool-get-max-threads pool)
  (with-mutex (mutex-get pool)
    (max-threads-get pool)))

;; This procedure will increase, or if 'delta' is negative reduce, the
;; maximum number of threads which the thread pool object will
;; currently run by the value of 'delta'.  The main purpose of this is
;; to enable a task to increment the maximum thread number where it is
;; about to enter a call which may block (non-asynchronously) for some
;; time, with a view to decrementing it later when it has finished
;; making blocking calls, so as to enable another thread to keep a
;; core active.  A with-thread-pool-increment macro is available which
;; will do this for you automatically in an exception-safe way (see
;; the documentation on that macro below).
;;
;; If 'delta' is negative and results in a max_threads value of less
;; than the current number of running threads, the number of threads
;; actually running will only be reduced as tasks complete, or as idle
;; timeouts expire.  This procedure does nothing if thread-pool-stop!
;; has previously been called.  This procedure is thread safe - any
;; thread may call it.
;;
;; If 'delta' is positive and tasks are currently queued for
;; execution, a new thread or threads will be started for the queued
;; tasks.  This procedure may therefore throw an exception if the
;; system is unable to start the required new thread(s).  Because
;; starting new threads can be time consuming, to minimize contention
;; new threads are started outside the pool's mutex, although internal
;; book-keeping is done within the mutex.  One consequence is that if
;; such an exception is thrown while another thread has concurrently
;; tried to reduce the size of the pool, the number of threads running
;; in the pool may be smaller than it was when this procedure was
;; called.  Where min-threads is 0, in certain circumstances after an
;; exception where no new threads can be started, the pool could have
;; no running threads in it (so that thread-pool-get-num-threads
;; returns 0) even though some tasks previously added to the pool
;; remain pending.  If the system can start no new threads even though
;; none are running in the pool, it will be significantly broken so it
;; is not usually worth troubling about this - the program is doomed
;; in that event whatever.  However if that is wrong and the cause of
;; the failure to start any threads can be addressed, then the thread
;; pool can be brought back into use by calling this procedure again
;; with a positive value (which can be preceded by a call with a
;; negative value to prevent too many threads trying to start).
;;
;; This procedure is first available in version 0.18 of this library.
(define (thread-pool-change-max-threads! pool delta)
  (let ((mutex (mutex-get pool)))
    ;; to minimize contention, we want to start any new threads
    ;; outside the mutex, but do the book-keeping within the mutex
    (let ((start-threads
	   (with-mutex mutex
	     (let ((sought (+ (max-threads-get pool) delta))
		   (min-threads (min-threads-get pool)))
	       (cond
		((stopped-get pool) #f)
		((< delta 0)
		 (max-threads-set! pool (cond
					 ((and (> min-threads 0)
					       (< sought min-threads))
					  min-threads)
					 ((< sought 1) 1)
					 (else sought)))
		 #f)
		((> delta 0)
		 (max-threads-set! pool sought)
		 (let ((num-threads (num-threads-get pool))
		       (new-num-threads (min (num-tasks-get pool) sought)))
		   (if (> new-num-threads num-threads)
		       (begin
			 (num-threads-set! pool new-num-threads)
			 (- new-num-threads num-threads))
		       #f)))
		(else #f))))))
      (when start-threads
	(do ((count 0 (1+ count)))
	    ((= count start-threads))
	  (catch #t
	    (lambda ()
	      (call-with-new-thread (lambda () (thread-loop pool #f))))
	    (lambda args
	      ;; roll back for any unstarted threads
	      (with-mutex mutex
		(num-threads-set! pool (+ (- (num-threads-get pool) start-threads) count))
		;; We could be down to 0 threads if all of these
		;; unfortunate events have occurred together: (i)
		;; min-threads is 0, (ii) in the period between this
		;; calling thread releasing the mutex acquired on
		;; entry to this procedure and acquiring it again on
		;; handling this exception, another thread tried,
		;; concurrently with this attempted increase, to
		;; reduce the max-threads' size of the pool by an
		;; amount equal to or more than its original size,
		;; (iii) during that period a number of tasks equal to
		;; that original max-threads' size have finished, and
		;; (iv) the attempt to launch new threads failed with
		;; an exception without launching even one of them.
		;; In such a case we should be able to launch a rescue
		;; thread because no other threads could be running in
		;; the pool.  If we still cannot launch a thread the
		;; program and/or system must be totally borked anyway
		;; and there is little we can do.
		(when (zero? (num-threads-get pool))
		  ;; if this fails, all is lost (that is, we may have
		  ;; queued tasks in the pool with no thread startable
		  ;; to run them)
		  (catch #t
		    (lambda ()
		      (call-with-new-thread (lambda () (thread-loop pool #f)))
		      (num-threads-set! pool 1))
		    (lambda args #f)))
		(when (and (stopped-get pool)
			   (blocking-get pool))
		  (broadcast-condition-variable (condvar-get pool)))
		(apply throw args)))))))))

;; This procedure returns the current non-blocking status of the
;; thread pool.  (See the documentation on the thread-pool-stop!
;; procedure for more information about what that means.)
;;
;; This procedure is thread safe (any thread may call it).
;;
;; This procedure is first available in version 0.18 of this library.
(define (thread-pool-get-non-blocking pool)
  (with-mutex (mutex-get pool)
    (not (blocking-get pool))))

;; This procedure sets the non-blocking status of the thread pool.  If
;; 'val' is #f, the thread-pool-stop procedure will block, if #t it
;; will not.  (See the documentation on the thread-pool-stop!
;; procedure for more information about this.)
;;
;; This procedure is thread safe (any thread may call it).
;;
;; This procedure will throw a 'thread-pool-error exception if it is
;; invoked after the thread pool object concerned has been closed by a
;; call to thread-pool-stop!.
;;
;; This procedure is first available in version 0.18 of this library.
(define (thread-pool-set-non-blocking! pool val)
  (with-mutex (mutex-get pool)
    (when (stopped-get pool)
      (throw 'thread-pool-error
	     "thread-pool-set-non-blocking!"
	     "thread-pool-set-non-blocking! applied to a thread pool which has been closed"
	     #f
	     #f))
    (blocking-set! pool (not val))))

;; This procedure returns the current idle time setting for the thread
;; pool, in milliseconds.
;;
;; This procedure is thread safe (any thread may call it).
;;
;; This procedure is first available in version 0.18 of this library.
(define (thread-pool-get-idle-time pool)
  (with-mutex (mutex-get pool)
    (idle-time-get pool)))

;; This procedure sets the current idle time for the thread pool,
;; namely the length of time in milliseconds that threads greater in
;; number than the minimum and not executing any tasks will remain in
;; existence waiting for new tasks.  This will only have effect for
;; threads in the pool which begin waiting for new tasks after this
;; procedure is called.
;;
;; This procedure is thread safe (any thread may call it).
;;
;; This procedure is first available in version 0.18 of this library.
(define (thread-pool-set-idle-time! pool millisecs)
  (with-mutex (mutex-get pool)
    (idle-time-set! pool millisecs)))

;; This procedure will cause the thread-pool object to stop running
;; tasks.  However, all tasks already running or queued for execution
;; will be permitted to execute and complete normally.  If the
;; thread-pool's non-blocking setting is set to #f, this procedure
;; will wait until all the tasks still to execute have finished before
;; returning, and if #t it will return straight away.
;;
;; After this procedure has been called, any attempt to add further
;; tasks with the thread-pool-add! procedure will fail, and that
;; procedure will throw a 'thread-pool-error exception.  The same
;; exception will be thrown if this procedure is applied to a thread
;; pool to which this procedure has previously been applied.
;;
;; This procedure is thread safe (any thread may call it) unless the
;; non-blocking setting is #f, in which case no task running on the
;; thread-pool object may call this procedure.
;;
;; This procedure is first available in version 0.18 of this library.
(define (thread-pool-stop! pool)
  (let ((mutex (mutex-get pool)))
    (with-mutex mutex
      (when (stopped-get pool)
	(throw 'thread-pool-error
	       "thread-pool-stop!"
	       "thread-pool-stop! applied to a thread pool which has been closed"
	       #f
	       #f))
      (stopped-set! pool #t)
      (let ((thread-count (num-threads-get pool)))
	;; we could be adding more 'kill-thread callbacks than
	;; necessary here, because as we are doing this a timeout on a
	;; thread might expire leading to its demise in that way, or a
	;; concurrent call to thread-pool-change-max-threads! or
	;; thread-pool-add! may have failed to start a thread and
	;; thrown an exception.  However, that doesn't matter - we
	;; just get left with a redundant callback in 'aq' which never
	;; gets used and disappears when the pool is garbage collected
	(do ((kill-count 0 (1+ kill-count)))
	    ((= kill-count thread-count))
	  (a-queue-push! (aq-get pool) (cons (lambda () (throw 'kill-thread)) #f)))
	(when (blocking-get pool)
	  (do ()
	      ((= (num-threads-get pool) 0))
	    (wait-condition-variable (condvar-get pool) mutex)))))))

;; This procedure adds a new task to the thread pool.  'task' must be
;; a thunk.  If one or more threads in the pool are currently blocking
;; and waiting for a task, then the task will begin executing
;; immediately in one of the threads.  If not, and the the number of
;; threads running in the pool is less than the value returned by
;; thread-pool-get-max-threads, a new thread will start and the task
;; will execute immediately in the new thread.  Otherwise, the task
;; will be queued for execution as soon as a thread becomes available.
;; Tasks will be executed in the order in which they are added to the
;; thread pool object.  This procedure is thread safe (any thread may
;; call it, including any task running on the thread pool object).
;;
;; An optional handler procedure may be passed to 'fail-handler' which
;; will be invoked if the task throws an exception.  If a task throws
;; an exception and no handler procedure is provided, the program will
;; terminate.  The 'fail-handler' procedure will be passed the same
;; arguments as if it were a guile catch handler (it is implemented
;; using catch).
;;
;; If this procedure starts a new thread (see above), it may throw an
;; exception if the system is unable to start the thread correctly.
;; This procedure will throw a 'thread-pool-error exception if it is
;; invoked after the thread pool object concerned has been closed by a
;; call to thread-pool-stop!.
;;
;; This procedure is first available in version 0.18 of this library.
(define* (thread-pool-add! pool task #:optional fail-handler)
  (let ((mutex (mutex-get pool)))
    ;; to minimize contention, we want to start a new thread outside
    ;; the mutex, but do the book-keeping within the mutex
    (let ((start-thread
	   ;; (i) check the pool has not been closed, (ii) check if we
	   ;; need to start a new thread, and (iii) increment the task
	   ;; count and, if a new thread is to be started, the thread
	   ;; count under a single mutex locking operation to ensure
	   ;; atomicity within the pool
	   (with-mutex mutex
	     (when (stopped-get pool)
	       (throw 'thread-pool-error
		      "thread-pool-add!"
		      "thread-pool-add! applied to a thread pool which has been closed"
		      #f
		      #f))
	     (let ((num-threads (num-threads-get pool))
		   (num-tasks (num-tasks-get pool)))
	       (if (and (>= num-tasks num-threads)
			(< num-threads (max-threads-get pool)))
		   (begin
		     (num-tasks-set! pool (1+ num-tasks))
		     (num-threads-set! pool (1+ num-threads))
		     #t)
		   (begin
		     (num-tasks-set! pool (1+ num-tasks))
		     #f))))))
      ;; if a thread is to be started, do it outside the mutex to
      ;; reduce contention: we will roll back if starting the thread
      ;; fails
      (when start-thread
	(catch #t
	  (lambda ()
	    (call-with-new-thread (lambda () (thread-loop pool #f))))
	  (lambda args
	    (with-mutex mutex
	      (num-tasks-set! pool (1- (num-tasks-get pool)))
	      (num-threads-set! pool (1- (num-threads-get pool)))
	      (when (and (stopped-get pool)
			 (blocking-get pool))
		(broadcast-condition-variable (condvar-get pool)))
	      (apply throw args))))))
    ;; we need to check again whether thread-pool-stop! has been
    ;; called between us releasing the mutex above and reaching here.
    ;; We need to hold the mutex when adding the task so that the
    ;; whole operation is atomic - otherwise if thread-pool-stop! is
    ;; called concurrently with thread-pool-add!, we cannot guarantee
    ;; that a task will either run or a 'thread-pool-error exception
    ;; will be thrown.  We must give this guarantee for
    ;; await-task-in-thread-pool! to work correctly.  That is not too
    ;; much of an additional point of contention, because
    ;; a-queue-push! is itself serialized.
    (with-mutex mutex
      (if (stopped-get pool)
	  (begin
	    ;; roll back if the pool has been stopped so we do not add
	    ;; the task after all to the pool
	    (num-tasks-set! pool (1- (num-tasks-get pool)))
	    (throw 'thread-pool-error
		   "thread-pool-add!"
		   "thread-pool-add! applied to a thread pool which has been closed"
		   #f
		   #f))
	  (catch #t
	    (lambda ()
	      (a-queue-push! (aq-get pool) (cons task fail-handler)))
	    (lambda args
	      ;; roll back if adding the task fails
	      (num-tasks-set! pool (1- (num-tasks-get pool)))
	      (apply throw args)))))))

;; This macro is intended to be called by a task running on a thread
;; pool which is about to make a blocking (non-asynchronous) call.  It
;; will increment the max-threads value of 'pool' by 1 (by calling
;; thread-pool-change-max-threads!) so as to enable a queued task to
;; keep a core active, and decrement it again when execution of the
;; body clauses has completed.
;;
;; The (i) increment, (ii) execution of body clauses, and (iii)
;; decrement, form the three branches of a dynamic-wind, so the
;; decrement automatically occurs if control leaves body execution
;; because of an exception or other jump.
;;
;; This macro is first available in version 0.18 of this library.
(define-syntax-rule (with-thread-pool-increment pool body0 body1 ...)
  (let ((p pool))
    (dynamic-wind
      (lambda () (thread-pool-change-max-threads! p 1))
      (lambda () body0 body1 ...)
      (lambda () (thread-pool-change-max-threads! p -1)))))

;; This is a convenience procedure whose signature is:
;;
;;   (await-task-in-thread-pool! await resume [loop] pool thunk [handler])
;;
;; The 'loop' argument is optional.  The procedure will run 'thunk' in
;; the thread pool specified by the 'pool' argument.  The result of
;; executing 'thunk' will then be posted to the event loop specified
;; by the 'loop' argument, or to the default event loop if no 'loop'
;; argument is provided or if #f is provided as the 'loop' argument
;; (pattern matching is used to detect the type of the third
;; argument), and will comprise this procedure's return value.  This
;; procedure is intended to be called within a waitable procedure
;; invoked by a-sync (which supplies the 'await' and 'resume'
;; arguments).  It will normally be necessary to call
;; event-loop-block! on 'loop' (or on the default event loop) before
;; invoking this procedure.
;;
;; If the optional 'handler' argument is provided, then that handler
;; will run if 'thunk' throws, and the return value of the handler
;; would become the return value of this procedure; otherwise the
;; program will terminate if an unhandled exception propagates out of
;; 'thunk'.  Note that unlike a handler passed to the thread-pool-add!
;; procedure, 'handler' will run in the event loop thread and not in a
;; thread pool thread.  Exceptions thrown by the handler procedure
;; will propagate out of event-loop-run! for the 'loop' event loop.
;;
;; This procedure calls 'await' and must (like the a-sync procedure)
;; be called in the same thread as that in which the 'loop' or default
;; event loop runs (as the case may be).
;;
;; This procedure calls event-post! in the 'loop' event loop, which
;; could be subject to throttling (see the documentation for the
;; make-event-loop procedure for further information).
;;
;; Exceptions may propagate out of this procedure if they arise while
;; setting up, which shouldn't happen unless the thread pool given by
;; the 'pool' argument has been closed (in which case a
;; 'thread-pool-error exception will arise), the thread pool tries to
;; start an additional native thread which the operating system fails
;; to supply (which would cause a system exception to arise) or memory
;; is exhausted.
;;
;; This procedure is first available in version 0.18 of this library.
(define (await-task-in-thread-pool! await resume . rest)
  (match rest
    ((loop pool thunk handler)
     (await-task-in-thread-pool-impl! await resume loop pool thunk handler))
    ((#f pool thunk)
     (await-task-in-thread-pool-impl! await resume #f pool thunk #f))
    (((? event-loop?) pool thunk)
     (await-task-in-thread-pool-impl! await resume (car rest) pool thunk #f))
    ((pool thunk handler)
     (await-task-in-thread-pool-impl! await resume #f pool thunk handler))
    ((pool thunk)
     (await-task-in-thread-pool-impl! await resume #f pool thunk #f))
    (_
     (error "Wrong number of arguments passed to await-task-in-thread-pool!" await resume rest))))

(define (await-task-in-thread-pool-impl! await resume loop pool thunk handler)
  (let ((loop (or loop (get-default-event-loop))))
    (when (not loop) 
      (error "No default event loop set for call to await-task-in-thread-pool!"))
    (if handler
	(thread-pool-add! pool
			  (lambda ()
			    (let ((res (thunk)))
			      (event-post! (lambda () (resume res))
					   loop)))
			  (lambda args
			    (event-post! (lambda () (resume (apply handler args)))
					 loop)))
	(thread-pool-add! pool
			  (lambda ()
			    (let ((res (thunk)))
			      (event-post! (lambda () (resume res))
					   loop)))))
    (await)))

;; This is a convenience procedure whose signature is:
;;
;;   (await-generator-in-thread-pool! await resume [loop] pool generator proc [handler])
;;
;; The loop argument is optional.  The 'generator' argument is a
;; procedure taking one argument, namely a yield argument (see the
;; documentation on the make-iterator procedure for further details).
;; This await-generator-in-pool procedure will cause 'generator' to
;; run as a task in the 'pool' thread pool, and whenever
;; 'generator' yields a value this will cause 'proc' to execute in the
;; event loop specified by the 'loop' argument, or in the default
;; event loop if no 'loop' argument is provided or if #f is provided
;; as the 'loop' argument.  'proc' should be a procedure taking a
;; single argument, namely the value yielded by the generator.

;; This procedure is intended to be called within a waitable procedure
;; invoked by a-sync (which supplies the 'await' and 'resume'
;; arguments).  It will normally be necessary to call
;; event-loop-block! on 'loop' (or on the default event loop) before
;; invoking this procedure.
;;
;; If the optional 'handler' argument is provided, then that handler
;; will run if 'generator' throws an exception; otherwise the program
;; will terminate if an unhandled exception propagates out of
;; 'generator'.  Note that unlike a handler passed to the
;; thread-pool-add! procedure, 'handler' will run in the event loop
;; thread and not in a thread pool thread.  This procedure will return
;; #f if the generator completes normally, or
;; 'guile-a-sync-thread-error if the generator throws an exception and
;; 'handler' is run (the 'guile-a-sync-thread-error symbol is reserved
;; to the implementation and should not be yielded by the generator).
;; Exceptions thrown by the handler procedure will propagate out of
;; event-loop-run! for the 'loop' event loop.
;;
;; This procedure calls 'await' and will return when the generator has
;; finished or, if 'handler' is provided, upon the generator raising
;; an exception.  This procedure must (like the a-sync procedure) be
;; called in the same thread as that in which the 'loop' or default
;; event loop runs (as the case may be).
;;
;; This procedure calls event-post! in both the 'loop' event loop,
;; which could be subject to throttling (see the documentation for the
;; make-event-loop procedure for further information).
;;
;; Exceptions may propagate out of this procedure if they arise while
;; setting up, which shouldn't happen unless the thread loop given by
;; the 'pool' argument has been closed (in which case an
;; 'thread-pool-error exception will arise), the thread pool tries to
;; start an additional native thread which the operating system fails
;; to supply (which would cause a system exception to arise) or memory
;; is exhausted.  Exceptions arising during the execution of 'proc',
;; if not caught locally, will propagate out of event-loop-run! for
;; 'loop' or the default event loop (as the case may be).
;;
;; This procedure is first available in version 0.18 of this library.
(define (await-generator-in-thread-pool! await resume . rest)
  (match rest
    ((loop pool generator proc handler)
     (await-generator-in-thread-pool-impl! await resume loop pool generator proc handler))
    ((#f pool generator proc)
     (await-generator-in-thread-pool-impl! await resume #f pool generator proc #f))
    (((? event-loop?) pool generator proc)
     (await-generator-in-thread-pool-impl! await resume (car rest) pool generator proc #f))
    ((pool generator proc handler)
     (await-generator-in-thread-pool-impl! await resume #f pool generator proc handler))
    ((pool generator proc)
     (await-generator-in-thread-pool-impl! await resume #f pool generator proc #f))
    (_
     (error "Wrong number of arguments passed to await-generator-in-thread-pool!" await resume rest))))

(define (await-generator-in-thread-pool-impl! await resume loop pool generator proc handler)
  (let ((loop (or loop (get-default-event-loop))))
    (when (not loop) 
      (error "No default event loop set for call to await-generator-in-thread-pool!"))
    (if handler
       (thread-pool-add! pool
			 (lambda ()
			   (let ((iter (make-iterator generator)))
			     (let next ((res (iter)))
			       (event-post! (lambda () (resume res))
					    loop)
			       (when (not (eq? res 'stop-iteration))
				 (next (iter))))))
			 (lambda args
			   (event-post! (lambda ()
					  (apply handler args)
					  (resume 'guile-a-sync-thread-error))
					loop)))
       (thread-pool-add! pool
			 (lambda ()
			   (let ((iter (make-iterator generator)))
			     (let next ((res (iter)))
			       (event-post! (lambda () (resume res))
					    loop)
			       (when (not (eq? res 'stop-iteration))
				 (next (iter)))))))))
  (let next ((res (await)))
    (cond
     ((eq? res 'stop-iteration)
      #f)
     ((eq? res 'guile-a-sync-thread-error)
      'guile-a-sync-thread-error)
     (else 
      (proc res)
      (next (await))))))
