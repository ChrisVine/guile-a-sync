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

(define-module (a-sync compose)
  #:use-module (a-sync coroutines) ;; for a-sync
  #:export (compose-a-sync
	    no-await))

;; This file provides the compose-a-sync macro.  This macro does two
;; things: first, it calls a-sync for you and deals with the resulting
;; 'await' and 'resume' procedures without exposing them, which for
;; many simple uses makes a-sync easier to use; and secondly it
;; enables asynchronous tasks to be more easily composed on an event
;; loop with intermediate results, by using a let* type syntax (in
;; fact, let* is used internally).  The signature of this macro is:
;;
;;   (compose-a-sync [loop] ((var await-exp0) ...) await-exp1 await-exp2 ...)
;;
;; The 'loop' argument of compose-a-sync is optional.  If an event
;; loop constructed by make-event-loop is passed to 'loop', then that
;; is the main loop on which the tasks will be composed, otherwise if
;; there is no 'loop' argument given, the default main loop will be
;; used.  This is followed by bindings which are optional (there need
;; not be any), each of which must be initialised by an expression
;; comprising the application of a 'compose-a-sync'-capable procedure,
;; and following the bindings there must be a body of
;; 'compose-a-sync'-capable procedures executed solely for the purpose
;; of asynchronous side effects (this macro does not, and cannot,
;; return a value because as soon as the first await is made control
;; is passed to the event loop).  As in the case of let*, unlike the
;; bindings the body cannot be empty - there must be at least one
;; expression comprising application of a 'compose-a-sync'-capable
;; procedure in the body.
;;
;; As in the case of let*, each 'compose-a-sync'-capable procedure
;; initializing a binding can see the values of the initializations
;; made prior to it.  Unlike let*, compose-a-sync blocks cannot be
;; nested within other compose-a-sync blocks.  Furthermore, within a
;; compose-a-sync block, the result obtained from a
;; 'compose-a-sync'-capable procedure cannot be passed directly as an
;; argument to another 'compose-a-sync'-capable procedure: the
;; intermediate result must be stored as the value of a binding in the
;; compose-a-sync block.
;;
;; A 'compose-a-sync'-capable procedure is one which takes an 'await'
;; and 'yield' procedure from a-sync as its first and second
;; arguments, and (if the optional 'loop' argument of this macro is
;; used) takes the event loop as its third argument, followed by such
;; further arguments as it requires.  All of the await-task!,
;; await-task-in-thread!, await-task-in-event-loop!, await-yield!,
;; await-generator!, await-generator-in-thread!,
;; await-generator-in-event-loop!, await-timeout!, await-sleep!,
;; await-getline!, await-geteveryline!, await-getsomelines!,
;; await-getblock!, await-geteveryblock!, await-getsomeblocks!,
;; await-put-bytevector!, await-put-string!, await-accept! and
;; await-connect! procedures provided by the (a-sync event-loop) and
;; (a-sync sockets) modules are 'compose-a-sync'-capable.  In
;; addition, to make an ordinary body of code which does not block
;; (and which does not need to invoke a-sync's await procedure) usable
;; by compose-a-sync, the no-await macro can be used to generate a
;; 'compose-a-sync'-capable procedure for it (see below).
;;
;; The await-glib-task, await-glib-task-in-thread,
;; await-glib-generator, await-glib-generator-in-thread,
;; await-glib-timeout, await-glib-getline, await-glib-getblock,
;; await-glib-put-bytevector and await-glib-put-string procedures in
;; the (a-sync gnome-glib) module also meet the
;; 'compose-a-sync'-capable requirements.
;;
;; Each binding is initialized as if sequentially (although it is done
;; asynchronously on the relevant event loop).  An initialization does
;; not begin until an earlier one has completed.  In addition, each
;; clause in the body is executed sequentially in turn, but does so
;; asynchronously on the event loop using 'await' semantics.
;;
;; When calling a 'compose-a-sync'-capable procedure within a
;; 'compose-a-sync' block (including when initializing its bindings),
;; the 'await' and 'yield' and event-loop arguments are not explicitly
;; passed to it.  The compose-a-sync macro will do it for you.  See
;; the example.scm and example-glib.scm files with the distribution
;; for further particulars.
;;
;; This macro must (like the a-sync procedure) be called in the same
;; thread as that in which the event loop runs.
(define-syntax compose-a-sync
  (syntax-rules ()
    ((_ ((var (await-proc0 arg0 ...)) ...)
	(await-proc1 arg1 ...)
	(await-proc2 arg2 ...) ...)
     (a-sync (lambda (await resume)
	       (let* ((var (await-proc0 await resume arg0 ...)) ...)
		 (await-proc1 await resume arg1 ...)
		 (await-proc2 await resume arg2 ...) ...))))
    ((_ loop ((var (await-proc0 arg0 ...)) ...)
	(await-proc1 arg1 ...)
	(await-proc2 arg2 ...) ...)
     (a-sync (lambda (await resume)
	       (let* ((var (await-proc0 await resume loop arg0 ...)) ...)
		 (await-proc1 await resume loop arg1 ...)
		 (await-proc2 await resume loop arg2 ...) ...))))))

;; This macro will generate a 'compose-a-sync'-capable procedure from
;; a body of code which does not block.  It can be passed to
;; compose-a-sync, either for use as an initializer or as a clause in
;; its body.  When used as an initializer, it evaluates to the value
;; of the last expression in the 'no-await' body.  See the example.scm
;; file with the distribution for further particulars.
;;
;; If the body throws an exception which is not caught locally, it
;; will propagate out of event-loop-run! or g-main-loop-run, as the
;; case may be.
(define-syntax no-await
  (syntax-rules ()
    ((_ body0 body1 ...)
     (lambda ignore
	body0 body1 ...))))
