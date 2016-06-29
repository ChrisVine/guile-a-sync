;; Copyright (C) 2014 and 2016 Chris Vine

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

(define-module (a-sync coroutines)
  #:export (make-iterator
	    make-coroutine
	    a-sync))

;; this procedure takes a generator procedure, namely a procedure
;; which has a 'yield' parameter for its first or only argument,
;; followed by such other arguments (other than the one for the
;; 'yield' parameter) as the generator procedure requires, and
;; constructs an iterator from them.  When the iterator (which
;; optionally takes no or one argument) is invoked, it will begin
;; executing the procedure unless and until the argument comprising
;; the yield procedure is called, which will cause the iterator to
;; suspend computation and instead return the value passed to yield,
;; if any (yield is a procedure taking no or one argument).  If
;; invoked again, the iterator will resume computation at the point
;; where it last left off (returning the value, if any, passed to the
;; iterator on resuming).  When the generator procedure has executed
;; to the end, the iterator returns 'stop-iteration.  This procedure
;; has some resemblance to call/ec, except that (i) instead of
;; executing the passed procedure immediately, it returns an iterator
;; which will do so, (ii) it is resumable, and (iii) the procedure to
;; be executed can receive starting arguments in addition to the
;; yield/break argument, to provide an alternative to binding them
;; with a lambda closure.  It is similar to ECMAScript generators and
;; python generators.
(define (make-iterator proc . args)
  (define tag (make-prompt-tag))
  (define send-back #f)
  (define (thunk)
    (apply proc
	   (lambda* (#:optional val)
	     (abort-to-prompt tag val)
	     send-back)
	   args)
    ;; the generator procedure has returned - reset thunk to do
    ;; nothing except return 'stop-iteration and return
    ;; 'stop-iteration after this last call to proc
    (set! thunk (lambda () 'stop-iteration))
    'stop-iteration)
  (lambda* (#:optional send-arg)
    (set! send-back send-arg)
    (call-with-prompt tag
		      thunk
		      (lambda (cont ret)
			(set! thunk cont)
			ret))))

;; this procedure takes a generator procedure, namely a procedure
;; which has a 'yield' parameter for its first or only argument,
;; followed by such other arguments (other than the one for the
;; 'yield' parameter) as the generator procedure requires, and
;; constructs a coroutine.  It is similar to make-iterator, in that it
;; takes a generator procedure and returns a lambda object (a
;; coroutine) which when called will begin executing the generator
;; procedure unless and until the argument comprising the yield
;; procedure is called, which will cause computation to be suspended.
;; However unlike make-iterator, the resumption continuation generated
;; on yielding is returned by the coroutine when yielding rather than
;; being stored internally in an iterator, so there is no explicit
;; retained mutable state.  The return value of the coroutine
;; comprises two values: first the resumption continuation, and second
;; the value (if any) passed to 'yield' when called.  If the returned
;; resumption continuation is subsequently called again, computation
;; will be resumed at the point where it last left off (the yield
;; procedure returning the value, if any, passed to the continuation
;; on resuming) until it completes or it again calls the yield
;; procedure.
;;
;; Upon the generator procedure finally completing, the value to which
;; it evaluates is returned by the resumption continuation together
;; with a continuation value of #f.  This differs from the behaviour
;; of make-iterator, which returns 'stop-iteration when the generator
;; procedure finishes to completion and ignores its return value.
(define (make-coroutine proc . args)
  (define tag (make-prompt-tag))
  (define (abort-handler cont ret)
    (define* (resume #:optional arg)
      (call-with-prompt
       tag
       (lambda () (cont arg))
       abort-handler))
    (values resume ret))
  ;; 'arg' is ignored - it is provided only for consistency with the
  ;; interface of resume
  (lambda* (#:optional arg)
	   (call-with-prompt
	    tag
	    (lambda ()
	      (values #f
		      (apply proc
			     (lambda* (#:optional arg)
				      (abort-to-prompt tag arg))
			     args)))
	    abort-handler)))
     
;; a-sync takes a waitable procedure (namely a procedure which takes
;; 'await' as its first parameter, which is a yield procedure obtained
;; by a call to make-iterator, and 'resume' as its second parameter,
;; which is an iterator constructed by make-iterator), followed by
;; such other arguments (if any) as the waitable procedure requires to
;; be passed on to it.  The 'resume' argument must only be called by
;; an asynchronous callback, and the 'await' argument must only be
;; called by the waitable procedure in order to block until the
;; callback is ready to let it resume.  When it unblocks, the 'await'
;; argument returns the value (if any) passed to 'resume' by the
;; callback.  This async procedure must be called in the same thread
;; as that in which the event loop runs.

;; None of the code in the waitable procedure should block on other
;; things in the program, except by calls to await (which do not in
;; fact block, even though they appear to do so).
;;
;; The way it works is that the call to a-sync will begin executing
;; the waitable procedure and will return as soon as the first (or
;; only) call to 'await' is made by that procedure, or as soon as the
;; waitable procedure returns if it makes no calls to 'await'.  Any
;; subsequent resumptions of the waitable procedure will take place in
;; the event loop concerned as delimited continuations, via the calls
;; to 'resume' made by the callbacks.  The effect of the waitable
;; procedure subsequently ending, or of further calls to 'await' being
;; made within the same waitable procedure, is to return control to
;; the event loop by recommencing execution at the point where the
;; most recent previous call to 'resume' was made by the last callback
;; to execute.
;;
;; An exception thrown in the waitable procedure before the first call
;; to 'await' which is not handled locally will propagate out of the
;; a-sync procedure normally.  Any exception thrown subsequently in
;; the waitable procedure which is not handled locally will propagate
;; into the previously called callback at the point where 'resume' was
;; last called.  If this is handled locally in the callback by putting
;; a catch block around resume, then control will be returned to the
;; event loop and the remainder of the waitable procedure will not
;; execute.  If that exception is not handled locally in the callback,
;; or if the callback throws an exception of its own, then it will
;; propagate out of the event loop.  If the event loop in the
;; event-loop module is used, this means that it will propagate out of
;; the call to event-loop-run!.  If an exception propagates out of
;; event-loop-run! for that or some other reason, then the event loop
;; will be left in a valid state and it will be as if event-loop-quit!
;; had been called on it, but it is then up to the user to catch that
;; exception once it is out of event-loop-run! if she does not want
;; the program to terminate.
;;
;; After the call to 'resume', the callback should normally just
;; return (with a #t or #f value in the case of a file watch or a
;; timeout on an event-loop object from the event loop module).  If
;; a-sync is used with a file watch or timeout on an event-loop object
;; constructed by make-event-loop, the watch callback or timeout
;; callback should normally, when the call to 'resume' returns, either
;; always return #f (so the callback only fires once) or always return
;; #t (so it is responsibility of the waitable procedure to terminate
;; the watch or timeout repetitions).  That way, there can never be a
;; case where the callback has been removed from the event loop by
;; returning false but the waitable procedure still thinks it has a
;; call to 'await' to be made.  The event-loop module has await-task!,
;; await-task-in-thread!, await-timeout!, a-sync-read-watch!,
;; await-getline!, await-geteveryline!, await-getsomelines! and
;; a-sync-write-watch! convenience procedures which will correctly set
;; this up for you automatically.  If those convenience procedures are
;; used, exceptions should always be handled locally in the waitable
;; procedure (and if the callback might throw, in the callback also)
;; if it is undesirable that uncaught exceptions propagate out of
;; event-loop-run!.  In the case of await-task-in-thread!, that
;; procedure also takes an optional handler argument which will handle
;; any exceptions thrown by the task: otherwise the task thread
;; throwing would terminate the program if not caught within the task.
;;
;; There can be as many calls to 'await' and asynchronous callbacks in
;; any one waitable procedure as wanted, to enable composition of
;; asynchronous operations.  However, you cannot run two or more
;; asynchronous tasks at the same time with the same await-resume pair
;; without an intervening call to await except by doing extra work,
;; because the first call to 'await' will match the first callback
;; which happens to call 'resume', and so on.  In such cases, 'resume'
;; would need to return something like a key-value pair so that the
;; result can be correctly identified.  Accordingly this practice is
;; discouraged.  Instead, when composing asynchronous tasks within any
;; one waitable procedure, operate on a 'start-task -->
;; await-on-result --> start-task --> await-on-result ...' basis, and
;; make calls to a-sync on separate waitable procedures for tasks
;; which are to run independently.  This is easy using the convenience
;; procedures mentioned above (see the examples).  A waitable
;; procedure can itself call a-sync to construct another await-resume
;; pair for the purpose of starting other asynchronous events.
;;
;; This procedure can be used with any event loop, including the glib
;; event loop provided by guile-gnome and so with gtk+ callbacks, and
;; with the event loop in the event-loop module.
(define (a-sync waitable . args)
  (letrec ((resume (make-iterator (lambda (await)
				  (apply waitable await resume args)))))
    (resume)))
