;;; Immutable, fixture-only driver for a fused System-pruning program.

(define-module (sk system-pruning-fused-driver)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (sk system-pruning-boundary)
  #:use-module (sk system-pruning-fixture-runtime)
  #:use-module (sk system-pruning-orchestrator)
  #:use-module (sk system-pruning-phase-engine)
  #:use-module (sk system-pruning-reconciliation)
  #:use-module (sk system-pruning-root-backend)
  #:use-module (sk system-pruning-transaction)
  #:use-module (srfi srfi-1)
  #:export (sk:main))

(define %program "guix-system-pruning-fused")
(define %guix-revision "a8391f2d7451c2463ba253ffa9872fa6f27485d7")
(define %guix-frontend
  "/gnu/store/mm52g4iy2hx36vn27h7y13cgc8zqzv5c-profile/bin/guix")
(define %guix-program
  "/gnu/store/0hzhxis25c15rag5412rhm2md38chi6x-guix-command")
(define %guile-version "3.0.11")
(define %guile-program
  "/gnu/store/f75z9sgss74ndiy1jnr02fippk1fjwkj-guile-wrapper/bin/guile")
(define %store-alphabet
  "0123456789abcdfghijklmnpqrsvwxyz")
(define %store-suffix "-system-pruning-loaded.scm")

(define (fail format-string . arguments)
  (format (current-error-port)
          "~a: FAIL: ~a~%"
          %program
          (apply format #f format-string arguments))
  (exit 1))

(define (ensure condition format-string . arguments)
  (unless condition
    (apply fail format-string arguments)))

(define (embedded-interface-ref name)
  (let ((interface
         (false-if-exception
          (resolve-interface '(sk system-pruning-embedded-inputs)))))
    (ensure interface "embedded-input module is unavailable")
    (module-ref interface name)))

(define (assert-startup-provenance)
  (let ((interface
         (false-if-exception
          (resolve-interface '(sk system-pruning-startup)))))
    (ensure interface "fused startup-provenance module is unavailable")
    (let ((assertion
           (module-ref interface 'sk:assert-fused-startup)))
      (ensure (procedure? assertion)
              "fused startup-provenance assertion is unavailable")
      (ensure (eq? (assertion) #t)
              "fused startup-provenance assertion did not return exact success"))))

(define (embedded-string label)
  ((embedded-interface-ref 'sk:embedded-input-string) label))

(define (embedded-identities)
  (embedded-interface-ref 'sk:embedded-input-identities))

(define (embedded-identity label)
  (let ((record (assq label (embedded-identities))))
    (ensure (and (list? record)
                 (= (length record) 3)
                 (string? (list-ref record 1))
                 (integer? (list-ref record 2)))
            "embedded identity is unavailable: ~a"
            label)
    record))

(define (store-hash? text)
  (and (= (string-length text) 32)
       (every (lambda (character)
                (string-index %store-alphabet character))
              (string->list text))))

(define (canonical-store-program)
  (let* ((interface
          (false-if-exception
           (resolve-interface '(sk system-pruning-startup))))
         (source
          (and interface
               (module-ref interface 'sk:fused-program-path))))
    (ensure (and source (absolute-file-name? source))
            "fused program filename is not absolute")
    (ensure (eq? 'regular (stat:type (lstat source)))
            "fused program is not a regular file")
    (let ((canonical
           (false-if-exception (canonicalize-path source))))
      (ensure (and canonical (string=? source canonical))
              "fused program filename is not canonical"))
    (ensure (string=? (dirname source) "/gnu/store")
            "fused program is outside the canonical store directory")
    (let* ((name (basename source))
           (suffix-length (string-length %store-suffix)))
      (ensure (= (string-length name) (+ 32 suffix-length))
              "fused program store name has the wrong length")
      (ensure (store-hash? (substring name 0 32))
              "fused program store hash is invalid")
      (ensure (string=? (substring name 32) %store-suffix)
              "fused program store suffix is invalid"))
    (let ((metadata (lstat source)))
      (ensure (= (stat:uid metadata) 0)
              "fused program is not owned by root")
      (ensure (zero? (logand (stat:perms metadata) #o222))
              "fused program is writable"))
    source))

(define (reported-guix-commits text)
  (let loop ((lines (string-split text #\newline))
             (channel #f)
             (result '()))
    (if (null? lines)
        (reverse result)
        (let ((line (car lines)))
          (cond
           ((string-prefix? "name: " line)
            (loop (cdr lines)
                  (substring line (string-length "name: "))
                  result))
           ((and channel
                 (string=? channel "guix")
                 (string-prefix? "commit: " line))
            (loop (cdr lines)
                  channel
                  (cons
                   (substring line (string-length "commit: "))
                   result)))
           ((string-null? line)
            (loop (cdr lines) #f result))
           (else
            (loop (cdr lines) channel result)))))))

(define (assert-guix-runtime)
  (let ((frontend
         (false-if-exception (canonicalize-path %guix-frontend)))
        (program
         (false-if-exception (canonicalize-path %guix-program))))
    (ensure (and frontend program
                 (string=? frontend %guix-program)
                 (string=? program %guix-program))
            "Guix frontend/program identity differs from the fused policy")
    (ensure (eq? 'regular (stat:type (lstat %guix-program)))
            "pinned Guix program is not a regular store file"))
  (let* ((port
          (open-pipe* OPEN_READ
                      %guix-frontend
                      "describe"
                      "--format=recutils"))
         (description (get-string-all port))
         (status (close-pipe port))
         (exit-value
          (false-if-exception (status:exit-val status)))
         (commits (reported-guix-commits description)))
    (ensure (and (integer? exit-value) (zero? exit-value))
            "pinned Guix revision query failed")
    (ensure (equal? commits (list %guix-revision))
            "pinned Guix revision differs from the fused policy"))
  #t)

(define (assert-runtime-identity)
  ;; Reject mutable and non-store copies before any external Guix process can
  ;; be launched.
  (let ((program-path (canonical-store-program)))
    (assert-startup-provenance)
    (ensure (not (= (getuid) 0))
            "fixture-only fused program refuses uid 0")
    (ensure (string=? (version) %guile-version)
            "running Guile version differs from the fused policy")
    (let ((actual-guile
           (false-if-exception (canonicalize-path "/proc/self/exe"))))
      (ensure (and actual-guile
                   (string=? actual-guile %guile-program))
              "running Guile executable differs from the fused policy"))
    (ensure (string=? (or (getenv "GUILE_AUTO_COMPILE") "") "0")
            "GUILE_AUTO_COMPILE must be exactly 0")
    (for-each
     (lambda (name)
       (ensure (not (getenv name))
               "inherited Guile search path is forbidden: ~a"
               name))
     '("GUILE_LOAD_PATH"
       "GUILE_LOAD_COMPILED_PATH"))
    (assert-guix-runtime)
    program-path))

(define (transaction-inputs)
  (embedded-interface-ref 'sk:embedded-transaction-inputs))

(define (transaction-records key fields)
  (let ((records
         (filter
          (lambda (record)
            (and (pair? record) (string=? (car record) key)))
          (sk:read-tsv-string (embedded-string 'manifest)))))
    (for-each
     (lambda (record)
       (ensure (= (length record) fields)
               "embedded transaction record has wrong shape: ~a"
               key))
     records)
    records))

(define (single-transaction-record key fields)
  (let ((records (transaction-records key fields)))
    (ensure (= (length records) 1)
            "embedded transaction record is not unique: ~a"
            key)
    (car records)))

(define (closed-ref records key)
  (let ((record (assq key records)))
    (ensure record "closed record is unavailable: ~a" key)
    (cdr record)))

(define (fixture-contract-manifest program-path)
  (let* ((sha (list-ref (embedded-identity 'manifest) 1))
         (program-root
          (string-append
           "/var/guix/gcroots/p52b-system-prune-program-"
           sha))
         (candidate-roots
          (map
           (lambda (record)
             (list "candidate"
                   (string-append "candidate-g" (list-ref record 1))
                   (list-ref record 1)
                   (list-ref record 4)))
           (transaction-records "delete" 5)))
         (old (single-transaction-record "old-bootcfg" 4))
         (new (single-transaction-record "new-bootcfg" 4))
         (roots
          (append
           candidate-roots
           (list
            (list "bootcfg-old" "old-bootcfg" "-" (list-ref old 3))
            (list "bootcfg-new" "new-bootcfg" "-" (list-ref new 3))))))
    `((schema . "p5.2b-system-prune-boundary/v1")
      (mode . "FIXTURE-ONLY")
      (authorization . "NOT-GRANTED")
      (manifest-sha . ,sha)
      (program-root . (,program-root ,program-path))
      (roots . ,roots)
      (phases . ,(sk:phase-engine-phase-registry roots)))))

(define (assert-fixture-contract program-path)
  (ensure (procedure? sk:root-backend?)
          "root-backend contract is unavailable")
  (let* ((manifest
          (sk:assert-phase-engine-manifest
           (fixture-contract-manifest program-path)))
         (program (cdr (assq 'program-root manifest)))
         (tuples (sk:orchestrator-root-tuples manifest))
         (cleanup (sk:terminal-cleanup-plan manifest "COMPLETE")))
    (ensure (string=? (cdr (assq 'mode manifest)) "FIXTURE-ONLY")
            "fused boundary mode is not FIXTURE-ONLY")
    (ensure (string=? (cdr (assq 'authorization manifest)) "NOT-GRANTED")
            "fused boundary authorization is not NOT-GRANTED")
    (ensure (equal? (car tuples) program)
            "fused program root is not first")
    (ensure (equal? (last cleanup)
                    (list "remove-program-root" (car program)))
            "fused program root is not cleanup-last")
    manifest))

(define (print-identity program-path)
  (let ((manifest (embedded-identity 'manifest))
        (registry (embedded-identity 'crash-registry))
        (grub (embedded-identity 'retained-grub)))
    (format
     #t
     "~a: PASS: action=fixture-identity path=~a program-sha256=~a program-size=~a manifest-sha256=~a manifest-size=~a registry-sha256=~a registry-size=~a retained-grub-sha256=~a retained-grub-size=~a guix-revision=~a guix-frontend=~a guix-program=~a guile-program=~a fixture-contract=PROGRAM-FIRST/PROGRAM-LAST mode=FIXTURE-ONLY authorization=NOT-GRANTED~%"
     %program
     program-path
     (sk:file-sha256 program-path)
     (stat:size (stat program-path))
     (list-ref manifest 1)
     (list-ref manifest 2)
     (list-ref registry 1)
     (list-ref registry 2)
     (list-ref grub 1)
     (list-ref grub 2)
     %guix-revision
     %guix-frontend
     %guix-program
     %guile-program)))

(define (assert-fixture-root-argument root)
  (ensure (and (string? root)
               (absolute-file-name? root))
          "fixture root is not absolute")
  (ensure (not (string=? root "/"))
          "live root is forbidden")
  root)

(define (assert-d4a-fixture-root root)
  (assert-fixture-root-argument root)
  (ensure (and (not (string-suffix? "/" root))
               (not (string-contains root "//"))
               (not
                (any (lambda (component)
                       (member component '("" "." "..")))
                     (cdr (string-split root #\/)))))
          "D4a fixture root is not normalized")
  (ensure (eq? 'directory (stat:type (lstat root)))
          "D4a fixture root is not a real directory")
  (let ((canonical
         (false-if-exception (canonicalize-path root))))
    (ensure (and canonical (string=? canonical root))
            "D4a fixture root is not canonical"))
  root)

(define (reconciliation-config root manifest)
  (let* ((installed
          (single-transaction-record "installed-grub" 5))
         (old
          (single-transaction-record "old-bootcfg" 4))
         (new
          (single-transaction-record "new-bootcfg" 4))
         (mode
          (string->number (list-ref installed 4) 10)))
    (ensure (and (integer? mode)
                 (>= mode 0)
                 (<= mode #o777))
            "installed GRUB mode is invalid")
    (sk:make-reconciliation-config
     root
     manifest
     (list (embedded-string 'old-grub-fixture) mode)
     (list (embedded-string 'retained-grub) mode)
     (list (list-ref old 2)
           (string-append root (list-ref old 3)))
     (list (list-ref new 2)
           (string-append root (list-ref new 3)))
     (getuid))))

(define (review-required? classification)
  (and (list? classification)
       (= (length classification) 3)
       (string? (car classification))
       (string=? (car classification) "REVIEW-REQUIRED")))

(define (accepted-reconciliation-state? manifest config)
  (let ((classification (sk:classify-reconciliation config)))
    (and (equal? manifest (closed-ref config 'manifest))
         (list? classification)
         (= (length classification) 3)
         (string? (car classification))
         (not (review-required? classification)))))

(define (call-with-reconciliation-phase
         manifest config label phase-active? thunk)
  ;; All five names belong to the closed central gate API and independently
  ;; reclassify this synthetic fixture.  They are not claims that D4a acquired
  ;; production System locks or a production root session.  The reconciler
  ;; also re-observes the exact effect immediately before THUNK.
  (ensure (procedure? phase-active?)
          "synthetic phase-activity observation is not callable")
  (sk:call-with-pre-phase-gate
   manifest
   label
   config
   `((protected
      . ,(lambda (actual-manifest _phase state)
           (and (eq? state config)
                (accepted-reconciliation-state?
                 actual-manifest state))))
     (journal
      . ,(lambda (actual-manifest _phase state)
           (and (eq? state config)
                (accepted-reconciliation-state?
                 actual-manifest state))))
     (roots
      . ,(lambda (actual-manifest _phase state)
           (and (eq? state config)
                (accepted-reconciliation-state?
                 actual-manifest state))))
     (session
      . ,(lambda (actual-manifest _phase state)
           (and (eq? state config)
                (not (phase-active?))
                (accepted-reconciliation-state?
                 actual-manifest state))))
     (quiescence
      . ,(lambda (actual-manifest _phase state)
           (and (eq? state config)
                (not (phase-active?))
                (accepted-reconciliation-state?
                 actual-manifest state)))))
   thunk))

(define (assert-initial-reconciliation config)
  (let ((classification (sk:classify-reconciliation config)))
    (ensure
     (equal? classification
             '("INITIAL-ELIGIBLE" "program-temporary-root" ()))
     "D4a runtime requires the exact INITIAL-ELIGIBLE fixture state: ~s"
     classification)
    classification))

(define (print-runtime-result result)
  (format
   #t
   "~a: PASS: action=~a adapter=IN-MEMORY root-role=READ-ONLY-ELIGIBILITY supplied-root-transaction-mutations=0 result=~a terminal=~a declared-phases=~a executed-phases=~a history=~a guards=~a effects=~a opened=~a closed=~a lock-scopes=~a mode=~a authorization=~a~%"
   %program
   (sk:fixture-runtime-result-ref result 'action)
   (sk:fixture-runtime-result-ref result 'result)
   (sk:fixture-runtime-result-ref result 'terminal)
   (length
    (sk:fixture-runtime-result-ref result 'declared-phases))
   (length
    (sk:fixture-runtime-result-ref result 'executed-phases))
   (length
    (sk:fixture-runtime-result-ref result 'history))
   (sk:fixture-runtime-result-ref result 'guard-count)
   (sk:fixture-runtime-result-ref result 'effect-count)
   (sk:fixture-runtime-result-ref result 'opened)
   (sk:fixture-runtime-result-ref result 'closed)
   (sk:fixture-runtime-result-ref result 'lock-scopes)
   (sk:fixture-runtime-result-ref result 'mode)
   (sk:fixture-runtime-result-ref result 'authorization)))

(define (run-d4a-fixture action root manifest)
  (let* ((config
          (reconciliation-config
           (assert-d4a-fixture-root root)
           manifest)))
    (assert-initial-reconciliation config)
    (let ((runtime
           (sk:make-fixture-runtime manifest)))
    (cond
     ((string=? action "fixture-points")
      (sk:verify-fixture-runtime runtime)
      (for-each
       (lambda (phase)
         (format #t "phase\t~a~%" phase))
       (sk:phase-engine-required-phases manifest))
      (format
       #t
       "~a: PASS: action=fixture-points adapter=IN-MEMORY root-role=READ-ONLY-ELIGIBILITY supplied-root-transaction-mutations=0 phases=~a mode=FIXTURE-ONLY authorization=NOT-GRANTED~%"
       %program
       (length (sk:phase-engine-required-phases manifest))))
     ((string=? action "fixture-verify")
      (print-runtime-result
       (sk:verify-fixture-runtime runtime)))
     (else
      (print-runtime-result
       (sk:run-fixture-runtime! runtime action)))))))

(define (run-reconciliation root manifest)
  (let* ((config
          (reconciliation-config
           (assert-d4a-fixture-root root)
           manifest))
         (phase-active? #f)
         (classification
          (sk:reconcile-synthetic!
           config
           (lambda (label thunk)
             (ensure (not phase-active?)
                     "synthetic reconciliation phase overlap: ~a"
                     label)
             (call-with-reconciliation-phase
              manifest
              config
              label
              (lambda () phase-active?)
              (lambda ()
                (dynamic-wind
                  (lambda () (set! phase-active? #t))
                  thunk
                  (lambda () (set! phase-active? #f)))))))))
    (ensure (not (review-required? classification))
            "synthetic reconciliation requires review: ~s"
            classification)
    (ensure (not phase-active?)
            "synthetic reconciliation left a phase active")
    (format
     #t
     "~a: PASS: action=fixture-reconcile adapter=SYNTHETIC-FILESYSTEM classification=~a next=~a required-locks=~s mode=FIXTURE-ONLY authorization=NOT-GRANTED~%"
     %program
     (list-ref classification 0)
     (list-ref classification 1)
     (list-ref classification 2))))

(define (run-legacy-fixture action root)
  ;; The legacy 98-case oracle remains available only under explicit legacy
  ;; action names.  Pin the revision internally instead of trusting caller
  ;; environment.
  (setenv "SK_GUIX_REVISION" %guix-revision)
  (sk:run-embedded-fixture-transaction
   (substring action (string-length "legacy-"))
   (embedded-string 'manifest)
   (list-ref (embedded-identity 'manifest) 1)
   (assert-fixture-root-argument root)
   (transaction-inputs)))

(define (run arguments)
  (let ((program-path (assert-runtime-identity)))
    (let ((manifest (assert-fixture-contract program-path)))
    (cond
     ((equal? arguments '("fixture-identity"))
      (print-identity program-path))
     ((and (= (length arguments) 2)
           (member (car arguments)
                   '("fixture-points"
                     "fixture-verify"
                     "fixture-apply"
                     "fixture-recover")))
      (run-d4a-fixture (car arguments) (cadr arguments) manifest))
     ((and (= (length arguments) 2)
           (string=? (car arguments) "fixture-reconcile"))
      (run-reconciliation (cadr arguments) manifest))
     ((and (= (length arguments) 2)
           (member (car arguments)
                   '("legacy-fixture-points"
                     "legacy-fixture-verify"
                     "legacy-fixture-apply"
                     "legacy-fixture-recover")))
      (run-legacy-fixture (car arguments) (cadr arguments)))
     (else
      (fail
       "usage: fixture-identity | fixture-points|fixture-verify|fixture-apply|fixture-recover|fixture-reconcile FIXTURE-ROOT | legacy-fixture-points|legacy-fixture-verify|legacy-fixture-apply|legacy-fixture-recover FIXTURE-ROOT"))))))

(define (sk:main arguments)
  "Run one closed fused-program action exactly once."
  (catch #t
    (lambda () (run arguments))
    (lambda (key . caught)
      (if (eq? key 'quit)
          (apply throw key caught)
          (fail "~s ~s" key caught)))))
