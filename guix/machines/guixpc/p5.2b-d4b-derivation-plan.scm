;;; Enumerate the store paths declared by one already-lowered D4b build plan.

(use-modules (guix derivations)
             (srfi srfi-1))

(define %program
  "p5.2b-d4b-derivation-plan")

(define (fail format-string . arguments)
  (format (current-error-port)
          "~a: FAIL: ~a~%"
          %program
          (apply format #f format-string arguments))
  (exit 1))

(define %store-prefix "/gnu/store/")

(define (containing-store-item path)
  (and (string? path)
       (string-prefix? %store-prefix path)
       (let* ((prefix-length (string-length %store-prefix))
              (tail (substring path prefix-length))
              (separator (string-index tail #\/))
              (item-length (or separator (string-length tail))))
         (and (> item-length 0)
              (substring path 0 (+ prefix-length item-length))))))

(define (top-level-store-path? path)
  (let ((item (containing-store-item path)))
    (and item (string=? item path))))

(define (builder-plan-entry builder)
  (cond
   ((containing-store-item builder) => identity)
   ((and (string? builder)
         (string-prefix? "builtin:" builder))
    'builtin)
   (else #f)))

(define arguments (cdr (command-line)))
(when (equal? arguments '("--self-check"))
  (unless
      (and
       (equal? (containing-store-item
                "/gnu/store/0123456789abcdfghijklmnpqrsvwxyz-guile/bin/guile")
               "/gnu/store/0123456789abcdfghijklmnpqrsvwxyz-guile")
       (equal? (containing-store-item
                "/gnu/store/0123456789abcdfghijklmnpqrsvwxyz-source")
               "/gnu/store/0123456789abcdfghijklmnpqrsvwxyz-source")
       (not (containing-store-item "/gnu/store/"))
       (not (containing-store-item "/tmp/not-store"))
       (eq? (builder-plan-entry "builtin:download") 'builtin)
       (not (builder-plan-entry "relative/builder")))
    (fail "store-item normalization self-check failed"))
  (format #t "~a: PASS: self-check~%" %program)
  (exit 0))

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

(define seen (make-hash-table))
(define paths '())

(define (record! path)
  (unless (top-level-store-path? path)
    (fail "derivation declares a non-store or nested path: ~s"
          path))
  (set! paths (cons path paths)))

(define (record-builder! builder)
  (let ((entry (builder-plan-entry builder)))
    (cond
     ((string? entry) (record! entry))
     ((eq? entry 'builtin) #t)
     (else
      (fail "derivation declares an unknown builder: ~s"
            builder)))))

(define (walk! derivation)
  (let ((file (derivation-file-name derivation)))
    (unless (hash-ref seen file #f)
      (hash-set! seen file #t)
      (record! file)
      (record-builder! (derivation-builder derivation))
      (for-each record! (derivation-sources derivation))
      (for-each
       (lambda (entry)
         (record! (derivation-output-path (cdr entry))))
       (derivation-outputs derivation))
      (for-each
       (lambda (input)
         (walk! (derivation-input-derivation input)))
       (derivation-inputs derivation)))))

(walk! (read-derivation-from-file derivation-path))
(for-each
 (lambda (path)
   (format #t "~a~%" path))
 (sort (delete-duplicates paths string=?)
       string<?))
