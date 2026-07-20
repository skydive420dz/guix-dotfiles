;;; Read the one output path of an already-lowered D4b derivation.

(use-modules (guix derivations))

(define %program
  "p5.2b-d4b-derivation-output")
(define %store-alphabet
  "0123456789abcdfghijklmnpqrsvwxyz")
(define %output-suffix
  "-system-pruning-loaded.scm")

(define (fail format-string . arguments)
  (format (current-error-port)
          "~a: FAIL: ~a~%"
          %program
          (apply format #f format-string arguments))
  (exit 1))

(define arguments (cdr (command-line)))
(unless (= (length arguments) 1)
  (fail "usage: ~a EXACT-DERIVATION" %program))

(define derivation-path (car arguments))
(unless (and (absolute-file-name? derivation-path)
             (string=? derivation-path
                       (canonicalize-path derivation-path))
             (string=? (dirname derivation-path)
                       "/gnu/store")
             (string-suffix? ".drv" derivation-path)
             (eq? 'regular
                  (stat:type (lstat derivation-path))))
  (fail "derivation is not one canonical store file: ~s"
        derivation-path))

(define outputs
  (derivation-path->output-paths derivation-path))
(unless (and (= (length outputs) 1)
             (pair? (car outputs))
             (string=? (caar outputs) "out")
             (string? (cdar outputs)))
  (fail "derivation does not have exactly one named out output: ~s"
        outputs))
(define output-path (cdar outputs))

(define (store-hash? text)
  (and (= (string-length text) 32)
       (let loop ((index 0))
         (or (= index (string-length text))
             (and (string-index %store-alphabet
                                (string-ref text index))
                  (loop (+ index 1)))))))

(define output-name (basename output-path))
(define suffix-length (string-length %output-suffix))
(unless (and (absolute-file-name? output-path)
             (string=? (dirname output-path) "/gnu/store")
             (= (string-length output-name)
                (+ 32 suffix-length))
             (store-hash? (substring output-name 0 32))
             (string=? (substring output-name 32)
                       %output-suffix))
  (fail "derivation output has the wrong store identity: ~s"
        output-path))

(format #t "~a~%" output-path)
