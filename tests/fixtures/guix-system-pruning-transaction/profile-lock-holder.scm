;;; Deterministic advisory-lock holder for the P5.2b-D3a fixture tests.

(use-modules (ice-9 format)
             (guix build syscalls))

(define %program "profile-lock-holder.scm")

(define (fail format-string . arguments)
  (format (current-error-port)
          "~a: FAIL: ~a~%"
          %program
          (apply format #f format-string arguments))
  (exit 1))

(define arguments (cdr (command-line)))

(unless (= (length arguments) 3)
  (fail "expected LOCK-PATH READY-PATH HOLD-SECONDS"))

(define lock-path (list-ref arguments 0))
(define ready-path (list-ref arguments 1))
(define hold-seconds
  (string->number (list-ref arguments 2) 10))

(unless (and hold-seconds
             (integer? hold-seconds)
             (> hold-seconds 0)
             (<= hold-seconds 30))
  (fail "HOLD-SECONDS must be an integer between 1 and 30"))

(with-file-lock/no-wait
 lock-path
 (lambda _ (fail "lock is already held: ~a" lock-path))
 (begin
   (call-with-output-file ready-path
     (lambda (port)
       (display "LOCKED\n" port)))
   (sleep hold-seconds)))
