;;; Behavioral conformance checks for the exact fused-program loader.

(define-module (sk system-pruning-fused-loader-behavior-check)
  #:export (sk:loader-proof-init!
            sk:loader-proof-main!))

(define %program-name
  "guix-system-pruning-fused-loader-behavior-check")

(define (%fail format-string . arguments)
  (format (current-error-port)
          "~a: FAIL: ~a~%"
          %program-name
          (apply format #f format-string arguments))
  (exit 1))

(define (%assert condition format-string . arguments)
  (unless condition
    (apply %fail format-string arguments)))

(define %arguments (cdr (command-line)))

(unless (or (= (length %arguments) 2)
            (= (length %arguments) 3))
  (%fail "usage: PROGRAM MODE [PRODUCTION-SUITE]"))

(define %fused-program (car %arguments))
(define %mode (cadr %arguments))
(define %production-suite
  (and (= (length %arguments) 3)
       (list-ref %arguments 2)))

 (unless (member %mode
                '("malformed-final"
                  "preexisting-final"
                  "production-suite"
                  "success"
                  "wrong-digest"))
  (%fail "unknown mode: ~a" %mode))
(if (string=? %mode "production-suite")
    (%assert %production-suite
             "production-suite mode requires one suite file")
    (%assert (not %production-suite)
             "canary mode accepts no suite file"))

(define %canonical-spec
  '((root-backend-source
     (sk system-pruning-root-backend))
    (boundary-source
     (sk system-pruning-boundary))
    (orchestrator-source
     (sk system-pruning-orchestrator))
    (reconciliation-source
     (sk system-pruning-reconciliation))
    (embedded-context-source
     (sk system-pruning-embedded-context))
    (transaction-core-source
     (sk system-pruning-transaction))
    (phase-engine-source
     (sk system-pruning-phase-engine))
    (fixture-runtime-source
     (sk system-pruning-fixture-runtime))
    (embedded-inputs-source
     (sk system-pruning-embedded-inputs))
    (fused-driver-source
     (sk system-pruning-fused-driver))))

(define %wrong-final-module
  '(sk system-pruning-loader-behavior-wrong))

(define %root-module
  (resolve-module '() #f #:ensure #f))

(define %initializer-events '())
(define %main-count 0)

(define (spec-for-label label)
  (let ((entry (assq label %canonical-spec)))
    (%assert entry "unknown canary label: ~a" label)
    entry))

(define (registered-module name)
  (nested-ref-module %root-module name))

(define (module-ready-label module)
  (and module
       (module-ref module 'sk:loader-proof-ready #f)))

(define (sk:loader-proof-init! label module previous-label)
  "Record one canary initializer after proving its dependency and identity."
  (let* ((spec (spec-for-label label))
         (expected-name (cadr spec))
         (registered (registered-module expected-name)))
    (%assert (and (module? module)
                  (equal? (module-name module) expected-name)
                  (eq? module registered))
             "initializer module identity drift: ~a"
             label)
    (%assert (eq? (module-ready-label module) label)
             "initializer ready binding drift: ~a"
             label)
    (if previous-label
        (let* ((previous-spec (spec-for-label previous-label))
               (previous-module
                (registered-module (cadr previous-spec))))
          (%assert (eq? (module-ready-label previous-module)
                        previous-label)
                   "initializer dependency is not ready: ~a"
                   label)
          (%assert (and (pair? %initializer-events)
                        (eq? (car %initializer-events)
                             previous-label))
                   "initializer dependency order drift: ~a"
                   label))
        (%assert (null? %initializer-events)
                 "first initializer did not run first"))
    (%assert (not (memq label %initializer-events))
             "initializer ran more than once: ~a"
             label)
    (set! %initializer-events
          (cons label %initializer-events))
    (format #t
            "loader-init\t~a\t~a~%"
            (length %initializer-events)
            label)
    #t))

(define (sk:loader-proof-main! arguments)
  "Record the one permitted canary main invocation."
  (%assert (equal? arguments '("loader-proof"))
           "canary main arguments drift: ~s"
           arguments)
  (%assert (= %main-count 0)
           "canary main ran more than once")
  (set! %main-count 1)
  (format #t "loader-main\t1~%")
  #t)

(define (variable-definition-name form)
  (and (list? form)
       (= (length form) 3)
       (eq? (car form) 'define)
       (symbol? (cadr form))
       (cadr form)))

(define (module-declaration-name form)
  (and (list? form)
       (>= (length form) 2)
       (eq? (car form) 'define-module)
       (list? (cadr form))
       (cadr form)))

(define (read-remaining-forms port)
  (let loop ((forms '()))
    (let ((form (read port)))
      (if (eof-object? form)
          (reverse forms)
          (loop (cons form forms))))))

(define (quoted-value-form? form name)
  (and (eq? (variable-definition-name form) name)
       (list? (caddr form))
       (= (length (caddr form)) 2)
       (eq? (car (caddr form)) 'quote)))

(define (assert-production-tail forms)
  (%assert (= (length forms) 5)
           "production tail form count drift: ~a"
           (length forms))
  (%assert (quoted-value-form? (list-ref forms 0)
                               '%fused-source-identities)
           "production identity-table definition drift")
  (%assert (quoted-value-form? (list-ref forms 1)
                               '%fused-source-packets)
           "production packet-table definition drift")
  (%assert
   (equal?
    (list-ref forms 2)
    '(define %prepared-fused-sources
       (sk:preflight-fused-sources
        %fused-source-identities
        %fused-source-packets)))
   "production preflight tail drift")
  (%assert
   (equal? (list-ref forms 3)
           '(sk:eval-fused-sources %prepared-fused-sources))
   "production evaluator tail drift")
  (%assert
   (equal? (list-ref forms 4)
           '(sk:invoke-fused-main (cdr (command-line))))
   "production main tail drift"))

(define (load-exact-loader-prefix path)
  (call-with-input-file path
    (lambda (port)
      ;; `current-filename' is a source macro.  Keeping the canonical store
      ;; filename on this port makes the frozen location guard evaluate
      ;; exactly as it does during a direct load.
      (set-port-filename! port path)
      (let loop ((active-module (current-module))
                 (startup-module #f)
                 (evaluated-count 0))
        (let ((form (read port)))
          (cond
           ((eof-object? form)
            (%fail "reached EOF before the frozen production tail"))
           ((eq? (variable-definition-name form)
                 '%fused-source-identities)
            (let ((tail
                   (cons form (read-remaining-forms port))))
              (assert-production-tail tail)
              (%assert startup-module
                       "startup module was not established")
              (%assert (> evaluated-count 20)
                       "loader prefix is unexpectedly short")
              (for-each
               (lambda (name)
                 (%assert
                  (procedure? (module-ref startup-module name #f))
                  "loader procedure is unavailable at cutoff: ~a"
                  name))
               '(sk:preflight-fused-sources
                 sk:eval-fused-sources
                 sk:invoke-fused-main))
              (list startup-module tail)))
           (else
            (let* ((declared-name
                    (module-declaration-name form))
                   (result
                    (eval form active-module)))
              (if declared-name
                  (begin
                    (%assert
                     (and (not startup-module)
                          (module? result)
                          (equal? declared-name
                                  '(sk system-pruning-startup))
                          (equal? (module-name result)
                                  declared-name))
                     "unexpected module declaration in loader prefix: ~s"
                     declared-name)
                    (loop result result (+ evaluated-count 1)))
                  (loop active-module
                        startup-module
                        (+ evaluated-count 1)))))))))))

(define %caller-module (current-module))
(define %loaded-prefix
  ;; The fused startup mutates its private Guile path environment.  Keep
  ;; Guile's lazy finalizer thread from being created while this test harness
  ;; reads and evaluates that exact prefix; otherwise Guile 3.0.11 reaches
  ;; scm_putenv with two threads and declares the mutation unspecified.
  ;; `dynamic-wind' restores normal collection before any source packet,
  ;; production suite, or canary is evaluated, including on a prefix failure.
  (dynamic-wind
    gc-disable
    (lambda ()
      (load-exact-loader-prefix %fused-program))
    gc-enable))
(define %startup-module (car %loaded-prefix))
(define %production-tail (cadr %loaded-prefix))

(%assert (eq? (current-module) %caller-module)
         "prefix evaluation changed the caller module")
(%assert
 (string=? (module-ref %startup-module 'sk:fused-program-path)
           %fused-program)
 "loader did not preserve the exact fused-program path")

(define %source-sha256
  (module-ref %startup-module 'source-sha256))
(define %source-size
  (module-ref %startup-module 'source-size))
(define %preflight
  (module-ref %startup-module 'sk:preflight-fused-sources))
(define %evaluate
  (module-ref %startup-module 'sk:eval-fused-sources))
(define %invoke-main
  (module-ref %startup-module 'sk:invoke-fused-main))

(define (write-canary-source port label module-name previous-label)
  (format port
          ";;; Closed loader-behavior canary: ~a.~%~%"
          label)
  (format port "(define-module ~s~%" module-name)
  (display
   "  #:use-module (sk system-pruning-fused-loader-behavior-check)\n"
   port)
  (if (eq? label 'fused-driver-source)
      (display
       "  #:export (sk:loader-proof-ready sk:main))\n\n"
       port)
      (display "  #:export (sk:loader-proof-ready))\n\n"
               port))
  (display "(define sk:loader-proof-ready '" port)
  (display label port)
  (display ")\n\n" port)
  (when (eq? label 'fused-driver-source)
    (display
     "(define (sk:main arguments)\n  (sk:loader-proof-main! arguments))\n\n"
     port))
  (display "(sk:loader-proof-init! '" port)
  (display label port)
  (display " (current-module) " port)
  (write (and previous-label
              (list 'quote previous-label))
         port)
  (display ")\n" port))

(define (canary-source label module-name previous-label)
  (call-with-output-string
    (lambda (port)
      (write-canary-source
       port label module-name previous-label))))

(define (packet spec source)
  (list (car spec)
        (cadr spec)
        (%source-sha256 source)
        (%source-size source)
        source))

(define %success-packets
  (let loop ((specs %canonical-spec)
             (previous-label #f)
             (packets '()))
    (if (null? specs)
        (reverse packets)
        (let* ((spec (car specs))
               (label (car spec))
               (source
                (canary-source
                 label
                 (cadr spec)
                 previous-label)))
          (loop (cdr specs)
                label
                (cons (packet spec source)
                      packets))))))

(define %wrong-final-source
  (string-append
   ";;; Digest-valid malformed final loader packet.\n\n"
   "(define-module (sk system-pruning-loader-behavior-wrong))\n\n"
   "(format #t \"loader-poison-init\\n\")\n"))

(define %malformed-packets
  (append
   (reverse (cdr (reverse %success-packets)))
   (list
    (packet (car (reverse %canonical-spec))
            %wrong-final-source))))

(define (packet-identity packet)
  (list (list-ref packet 0)
        (list-ref packet 1)
        (list-ref packet 2)
        (list-ref packet 3)))

(define (packet-identities packets)
  (map packet-identity packets))

(define %wrong-digest-packets
  (let* ((first (car %success-packets))
         (wrong-first
          (list (list-ref first 0)
                (list-ref first 1)
                (make-string 64 #\0)
                (list-ref first 3)
                (list-ref first 4))))
    (cons wrong-first (cdr %success-packets))))

(define (caught-exception thunk)
  (catch #t
    (lambda ()
      (thunk)
      #f)
    (lambda (key . arguments)
      (cons key arguments))))

(define (expected-startup-exception? caught message)
  (equal?
   caught
   `(misc-error
     #f
     "~A ~S"
     ("fused startup provenance failure" ,message)
     #f)))

(define (assert-no-initializer)
  (%assert (null? %initializer-events)
           "a canary initializer ran before refusal: ~s"
           (reverse %initializer-events))
  (%assert (= %main-count 0)
           "canary main ran before refusal"))

(define (assert-expected-modules-absent)
  (for-each
   (lambda (spec)
     (%assert (not (registered-module (cadr spec)))
              "expected module exists after refusal: ~s"
              (cadr spec)))
   %canonical-spec))

(define (run-malformed-final)
  (let ((caught
         (caught-exception
          (lambda ()
            (%preflight
             (packet-identities %malformed-packets)
             %malformed-packets)))))
    (%assert
     (expected-startup-exception?
      caught
      "fused source has another declared module")
     "malformed final packet produced another failure: ~s"
     caught)
    (assert-no-initializer)
    (assert-expected-modules-absent)
    (%assert (not (registered-module %wrong-final-module))
             "malformed final module was initialized")))

(define (run-wrong-digest)
  (let ((caught
         (caught-exception
          (lambda ()
            (%preflight
             (packet-identities %wrong-digest-packets)
             %wrong-digest-packets)))))
    (%assert
     (expected-startup-exception?
      caught
      "fused source packet SHA256 drift")
     "wrong packet digest produced another failure: ~s"
     caught)
    (assert-no-initializer)
    (assert-expected-modules-absent)))

(define (run-preexisting-final)
  (let* ((driver-name
          (cadr (car (reverse %canonical-spec))))
         (seed
          (resolve-module driver-name #f #:ensure #t))
         (marker (list 'preexisting-final-marker)))
    (module-define! seed 'sk:loader-proof-seed marker)
    (let ((caught
           (caught-exception
            (lambda ()
              (%preflight
               (packet-identities %success-packets)
               %success-packets)))))
      (%assert
       (expected-startup-exception?
        caught
        "fused project module already exists")
       "preexisting final module produced another failure: ~s"
       caught)
      (assert-no-initializer)
      (for-each
       (lambda (spec)
         (unless (equal? (cadr spec) driver-name)
           (%assert (not (registered-module (cadr spec)))
                    "module initialized before preexisting refusal: ~s"
                    (cadr spec))))
       %canonical-spec)
      (%assert (eq? seed (registered-module driver-name))
               "preexisting module registry identity changed")
      (%assert
       (eq? marker
            (module-ref seed 'sk:loader-proof-seed #f))
       "preexisting module marker changed"))))

(define (run-success)
  (let ((prepared
         (%preflight
          (packet-identities %success-packets)
          %success-packets)))
    (%assert (eq? (current-module) %caller-module)
             "preflight changed the caller module")
    (%evaluate prepared)
    (%assert (eq? (current-module) %caller-module)
             "evaluator did not restore the caller module")
    (%assert
     (equal? (reverse %initializer-events)
             (map car %canonical-spec))
     "initializer order drift: ~s"
     (reverse %initializer-events))
    (%assert (= %main-count 0)
             "canary main ran during module initialization")
    (%invoke-main '("loader-proof"))
    (%assert (eq? (current-module) %caller-module)
             "main invocation changed the caller module")
    (%assert (= %main-count 1)
             "canary main invocation count drift")))

(define (quoted-definition-value form)
  (cadr (caddr form)))

(define (run-production-suite)
  (%assert (and (absolute-file-name? %production-suite)
                (file-exists? %production-suite)
                (eq? 'regular
                     (stat:type (lstat %production-suite))))
           "production suite is not one absolute regular file: ~s"
           %production-suite)
  (let* ((identities
          (quoted-definition-value
           (list-ref %production-tail 0)))
         (packets
          (quoted-definition-value
           (list-ref %production-tail 1)))
         (prepared (%preflight identities packets)))
    (%assert (eq? (current-module) %caller-module)
             "production preflight changed the caller module")
    (%evaluate prepared)
    (%assert (eq? (current-module) %caller-module)
             "production evaluator did not restore the caller module")
    (primitive-load %production-suite)
    (%assert (eq? (current-module) %caller-module)
             "production suite changed the caller module")))

(assert-expected-modules-absent)

(cond
 ((string=? %mode "malformed-final")
  (run-malformed-final))
 ((string=? %mode "preexisting-final")
  (run-preexisting-final))
 ((string=? %mode "wrong-digest")
  (run-wrong-digest))
 ((string=? %mode "production-suite")
  (run-production-suite))
 ((string=? %mode "success")
  (run-success))
 (else
  (%fail "unreachable mode: ~a" %mode)))

(format #t
        "~a: PASS: mode=~a~%"
        %program-name
        %mode)
