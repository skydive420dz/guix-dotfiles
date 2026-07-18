;;; Read-only closure accounting for guix-generation-retention.

(use-modules ((guix store)
              #:select (find-roots
                        path-info-nar-size
                        query-path-info
                        requisites
                        valid-path?
                        with-store))
             (ice-9 format)
             (ice-9 hash-table)
             (ice-9 match)
             (ice-9 rdelim)
             (srfi srfi-1)
             (srfi srfi-13))

(define %program "guix-generation-retention-estimator")
(define %schema "p5.1-store-estimate/v1")
(define %store-prefix "/gnu/store/")

(define (fail format-string . arguments)
  (apply format
         (current-error-port)
         (string-append %program ": FAIL: " format-string "~%")
         arguments)
  (exit 1))

(define (usage)
  (format (current-error-port)
          "usage: guix repl -q -- FILE CANDIDATE_TARGETS RETAINED_TARGETS IGNORED_ROOTS~%")
  (exit 64))

(define (unsafe-field-character? character)
  (or (char=? character #\nul)
      (char=? character #\tab)
      (char=? character #\newline)
      (char=? character #\return)))

(define (safe-field? value)
  (and (string? value)
       (not (string-null? value))
       (not (any unsafe-field-character? (string->list value)))))

(define (absolute-path? value)
  (and (safe-field? value)
       (char=? (string-ref value 0) #\/)))

(define (normalized-absolute-path? value)
  (and (absolute-path? value)
       (or (string=? value "/")
           (not (string-suffix? "/" value)))
       (not (string-contains value "//"))
       (not (string-contains value "/./"))
       (not (string-contains value "/../"))
       (not (string-suffix? "/." value))
       (not (string-suffix? "/.." value))))

(define (lower-case-alpha-numeric? character)
  (or (char-numeric? character)
      (and (char>=? character #\a)
           (char<=? character #\z))))

(define (store-item? value)
  (and (normalized-absolute-path? value)
       (string-prefix? %store-prefix value)
       (let ((base (string-drop value (string-length %store-prefix))))
         (and (> (string-length base) 33)
              (not (string-index base #\/))
              (char=? (string-ref base 32) #\-)
              (every lower-case-alpha-numeric?
                     (string->list (string-take base 32)))))))

(define (regular-input-file? file)
  (and (normalized-absolute-path? file)
       (catch 'system-error
         (lambda ()
           (eq? 'regular (stat:type (stat file))))
         (lambda arguments
           #f))))

(define (read-lines file label predicate)
  (unless (regular-input-file? file)
    (fail "~a input is not a readable absolute regular file: ~a" label file))
  (let ((lines
         (call-with-input-file
             file
           (lambda (port)
             (let loop ((line (read-line port))
                        (result '()))
               (if (eof-object? line)
                   (reverse result)
                   (begin
                     (unless (predicate line)
                       (fail "invalid ~a entry: ~s" label line))
                     (loop (read-line port) (cons line result)))))))))
    (let ((sorted (sort lines string<?)))
      (when (let loop ((remaining sorted))
              (match remaining
                (() #f)
                ((_item) #f)
                ((left right . rest)
                 (or (string=? left right)
                     (loop (cons right rest))))))
        (fail "~a input contains a duplicate entry" label))
      sorted)))

(define (make-string-set values)
  (let ((result (make-hash-table (max 31 (* 2 (length values))))))
    (for-each (lambda (value)
                (hash-set! result value #t))
              values)
    result))

(define (string-set-contains? set value)
  (hash-ref set value #f))

(define (unique-sorted values)
  (delete-duplicates (sort values string<?) string=?))

(define (difference values excluded)
  (let ((excluded-set (make-string-set excluded)))
    (filter (lambda (value)
              (not (string-set-contains? excluded-set value)))
            values)))

(define (root-pair<? left right)
  (or (string<? (car left) (car right))
      (and (string=? (car left) (car right))
           (string<? (cdr left) (cdr right)))))

(define (normalize-root-snapshot roots)
  (let ((pairs
         (map (match-lambda
                (((? string? root) . (? string? target))
                 (unless (normalized-absolute-path? root)
                   (fail "daemon returned an invalid root path: ~s" root))
                 (unless (store-item? target)
                   (fail "daemon returned an invalid root target: ~s" target))
                 (cons root target))
                (other
                 (fail "daemon returned a malformed root record: ~s" other)))
              roots)))
    (let loop ((remaining (sort pairs root-pair<?))
               (previous-root #f)
               (previous-target #f)
               (result '()))
      (match remaining
        (()
         (reverse result))
        (((root . target) . rest)
         (cond
          ((and previous-root (string=? root previous-root))
           (unless (string=? target previous-target)
             (fail "one root has multiple targets: ~a" root))
           (loop rest previous-root previous-target result))
          (else
           (loop rest root target (cons (cons root target) result)))))))))

(define (validate-paths-local store paths label)
  (for-each (lambda (path)
              (unless (valid-path? store path)
                (fail "~a is not a valid local store item: ~a" label path)))
            paths))

(define (closure store paths)
  (if (null? paths)
      '()
      (let ((items (unique-sorted (requisites store paths))))
        (for-each (lambda (item)
                    (unless (store-item? item)
                      (fail "daemon returned an invalid closure item: ~s" item)))
                  items)
        items)))

(define (set-union left right)
  (unique-sorted (append left right)))

(define (set-difference left right)
  (difference left right))

(define (nar-bytes store paths)
  (fold (lambda (path total)
          (let ((info (query-path-info store path)))
            (unless info
              (fail "missing local path information: ~a" path))
            (let ((size (path-info-nar-size info)))
              (unless (and (integer? size) (>= size 0))
                (fail "invalid NAR size for ~a: ~s" path size))
              (+ total size))))
        0
        paths))

(define (root-paths snapshot)
  (map car snapshot))

(define (root-targets snapshot)
  (map cdr snapshot))

(define (select-persistent-roots snapshot ignored)
  (let ((ignored-set (make-string-set ignored)))
    (filter (lambda (pair)
              (not (string-set-contains? ignored-set (car pair))))
            snapshot)))

(define (validate-ignored-roots snapshot
                                ignored
                                candidate-targets
                                retained-targets)
  (let ((snapshot-by-root (make-hash-table))
        (eligible-target-set
         (make-string-set (append candidate-targets retained-targets))))
    (for-each (lambda (pair)
                (hash-set! snapshot-by-root (car pair) (cdr pair)))
              snapshot)
    (for-each
     (lambda (root)
       (let ((target (hash-ref snapshot-by-root root #f)))
         (unless target
           (fail "ignored root is absent from the daemon snapshot: ~a" root))
         (unless (string-set-contains? eligible-target-set target)
           (fail "ignored root targets neither a candidate nor retained closure: ~a -> ~a"
                 root target))))
     ignored)
    (let ((ignored-targets
           (map (lambda (root)
                  (hash-ref snapshot-by-root root))
                ignored)))
      (for-each
       (lambda (candidate)
         (unless (member candidate ignored-targets string=?)
           (fail "candidate closure has no ignored generation root: ~a"
                 candidate)))
       candidate-targets))))

(define (validate-retained-roots persistent retained-targets)
  (let ((persistent-target-set
         (make-string-set (root-targets persistent))))
    (for-each
     (lambda (target)
       (unless (string-set-contains? persistent-target-set target)
         (fail "retained closure has no persistent generation root: ~a"
               target)))
     retained-targets)))

(define (render-output persistent
                       candidate-union
                       exclusive-policy
                       exclusive-persistent
                       candidate-bytes
                       policy-bytes
                       persistent-bytes)
  (call-with-output-string
    (lambda (port)
      (format port "helper-schema\t~a~%" %schema)
      (for-each
       (lambda (pair)
         (format port "known-root\t~a\t~a\tpersistent~%"
                 (car pair)
                 (cdr pair)))
       persistent)
      (format port "estimate\tcandidate-closure-union\t~a\t~a\tmeasurement~%"
              (length candidate-union)
              candidate-bytes)
      (format port
              "estimate\tcandidate-exclusive-vs-policy\t~a\t~a\tforward-references-only~%"
              (length exclusive-policy)
              policy-bytes)
      (format port
              "estimate\tcandidate-exclusive-vs-persistent-known-roots\t~a\t~a\tforward-references-only~%"
              (length exclusive-persistent)
              persistent-bytes)
      (format port "estimate\tguaranteed-reclaimable\t0\t0\tlower-bound~%")
      (format port
              "coverage\tpersistent-roots\tdaemon-find-roots-snapshot-minus-proposed-generation-links~%")
      (format port
              "coverage\tgc-derivation-policy\tnot-modeled~%")
      (format port
              "coverage\tprocess-roots\tnot-enumerated~%")
      (format port
              "coverage\ttemporary-roots\tnot-enumerated~%")
      (format port
              "coverage\tfilesystem-allocation\tnar-bytes-only-hardlinks-and-blocks-not-modeled~%")
      (format port "helper-status\tPASS~%"))))

(define (main arguments)
  (unless (= (length arguments) 4)
    (usage))
  (let* ((candidate-file (list-ref arguments 1))
         (retained-file (list-ref arguments 2))
         (ignored-file (list-ref arguments 3))
         (candidate-targets
          (read-lines candidate-file "candidate target" store-item?))
         (retained-targets
          (read-lines retained-file "retained target" store-item?))
         (ignored-roots
          (read-lines ignored-file
                      "ignored root"
                      normalized-absolute-path?)))
    (when (null? retained-targets)
      (fail "retained target input is empty"))
    (when (any (lambda (candidate)
                 (member candidate retained-targets string=?))
               candidate-targets)
      (fail "candidate and retained target inputs overlap"))
    (with-store store
      (validate-paths-local store candidate-targets "candidate target")
      (validate-paths-local store retained-targets "retained target")
      (let* ((roots-before
              (normalize-root-snapshot (find-roots store)))
             (_ (validate-ignored-roots
                 roots-before
                 ignored-roots
                 candidate-targets
                 retained-targets))
             (persistent
              (select-persistent-roots roots-before ignored-roots))
             (_ (validate-retained-roots persistent retained-targets))
             (persistent-targets
              (unique-sorted (root-targets persistent)))
             (_ (validate-paths-local
                 store
                 persistent-targets
                 "persistent root target"))
             (candidate-union (closure store candidate-targets))
             (retained-union (closure store retained-targets))
             (persistent-union (closure store persistent-targets))
             (exclusive-policy
              (set-difference candidate-union retained-union))
             (exclusive-persistent
              (set-difference
               candidate-union
               (set-union retained-union persistent-union)))
             (candidate-bytes (nar-bytes store candidate-union))
             (policy-bytes (nar-bytes store exclusive-policy))
             (persistent-bytes (nar-bytes store exclusive-persistent))
             (output
              (render-output persistent
                             candidate-union
                             exclusive-policy
                             exclusive-persistent
                             candidate-bytes
                             policy-bytes
                             persistent-bytes))
             (roots-after
              (normalize-root-snapshot (find-roots store))))
        (unless (equal? roots-before roots-after)
          (fail "persistent root snapshot changed during estimation"))
        (display output)))))

(main (command-line))
