;;; Fixture-only command driver for the P5.2b-D3a transaction core.

(use-modules (ice-9 format)
             (sk system-pruning-transaction))

(define %program "guix-system-pruning-transaction")

(define (fail format-string . arguments)
  (format (current-error-port)
          "~a: FAIL: ~a~%"
          %program
          (apply format #f format-string arguments))
  (exit 1))

(define arguments (cdr (command-line)))

(unless (= (length arguments) 4)
  (fail "expected ACTION MANIFEST FIXTURE-ROOT REPOSITORY"))

(catch 'sk-system-pruning-transaction
  (lambda ()
    (apply sk:run-fixture-transaction arguments))
  (lambda (_key message)
    (fail "~a" message)))
