;;; Deterministic tests for the pure fused pruning-program renderer.

(use-modules (gcrypt hash)
             (guix base16)
             (ice-9 textual-ports)
             (rnrs bytevectors)
             (sk system-pruning-fused-source)
             (srfi srfi-1))

(define (fail format-string . arguments)
  (format (current-error-port)
          "guix-system-pruning-fused-source-check: FAIL: ~a~%"
          (apply format #f format-string arguments))
  (exit 1))

(define (assert condition format-string . arguments)
  (unless condition
    (apply fail format-string arguments)))

(define (assert-equal actual expected label)
  (assert (equal? actual expected)
          "~a: expected ~s, got ~s"
          label expected actual))

(define (fails? thunk)
  (catch #t
    (lambda ()
      (thunk)
      #f)
    (lambda _ #t)))

(define (text-sha256 text)
  (bytevector->base16-string
   (bytevector-hash (string->utf8 text) (hash-algorithm sha256))))

(define arguments (cdr (command-line)))
(unless (= (length arguments) 2)
  (fail "expected repository and rendered-output arguments"))
(define repo (car arguments))
(define rendered-output (cadr arguments))

(define (repo-text relative)
  (let ((file (string-append repo "/" relative)))
    (assert (and (file-exists? file)
                 (eq? 'regular (stat:type (lstat file))))
            "repository input is not a regular file: ~a"
            relative)
    (call-with-input-file file get-string-all)))

(define (source-forms text)
  (let ((port (open-input-string text)))
    (let loop ((forms '()))
      (let ((form (read port)))
        (if (eof-object? form)
            (reverse forms)
            (loop (cons form forms)))))))

(define (definition-form forms name)
  (find
   (lambda (form)
     (and (list? form)
          (>= (length form) 3)
          (eq? (car form) 'define)
          (pair? (cadr form))
          (eq? (caadr form) name)))
   forms))

(define (variable-definition-form forms name)
  (find
   (lambda (form)
     (and (list? form)
          (= (length form) 3)
          (eq? (car form) 'define)
          (eq? (cadr form) name)))
   forms))

(define (form-index forms expected)
  (let loop ((rest forms)
             (index 0))
    (cond
     ((null? rest) #f)
     ((equal? (car rest) expected) index)
     (else (loop (cdr rest) (+ index 1))))))

(define (tree-count tree value)
  (cond
   ((pair? tree)
    (+ (tree-count (car tree) value)
       (tree-count (cdr tree) value)))
   ((equal? tree value) 1)
   (else 0)))

(define (subform-count tree predicate)
  (+ (if (predicate tree) 1 0)
     (if (pair? tree)
         (+ (subform-count (car tree) predicate)
            (subform-count (cdr tree) predicate))
         0)))

(define inputs
  `((root-backend-source
     . ,(repo-text
         "guix/modules/sk/system-pruning-root-backend.scm"))
    (boundary-source
     . ,(repo-text
         "guix/modules/sk/system-pruning-boundary.scm"))
    (orchestrator-source
     . ,(repo-text
         "guix/modules/sk/system-pruning-orchestrator.scm"))
    (reconciliation-source
     . ,(repo-text
         "guix/modules/sk/system-pruning-reconciliation.scm"))
    (embedded-context-source
     . ,(repo-text
         "guix/modules/sk/system-pruning-embedded-context.scm"))
    (transaction-core-source
     . ,(repo-text
         "guix/modules/sk/system-pruning-transaction.scm"))
    (phase-engine-source
     . ,(repo-text
         "guix/modules/sk/system-pruning-phase-engine.scm"))
    (fixture-runtime-source
     . ,(repo-text
         "guix/modules/sk/system-pruning-fixture-runtime.scm"))
    (fused-driver-source
     . ,(repo-text
         "scripts/guix-system-pruning-fused-driver.scm"))
    (manifest
     . ,(repo-text
         "tests/fixtures/guix-system-pruning-transaction/manifest.tsv"))
    (crash-registry
     . ,(repo-text
         "tests/fixtures/guix-system-pruning-transaction/phase-registry.tsv"))
    (retained-grub
     . ,(repo-text
         "docs/audits/data/2026-07-19-p5.2b-d2b-retained-grub.cfg"))
    (legacy-driver
     . ,(repo-text
         "scripts/guix-system-pruning-transaction.scm"))
    (legacy-launcher
     . ,(repo-text
         "scripts/guix-system-pruning-transaction"))
    (profile-lock-holder
     . ,(repo-text
         "tests/fixtures/guix-system-pruning-transaction/profile-lock-holder.scm"))
    (old-grub-fixture
     . ,(repo-text
         "tests/fixtures/guix-system-pruning-transaction/old-grub.cfg"))
    (pins-fixture
     . ,(repo-text
         "tests/fixtures/guix-system-pruning-transaction/generation-pins.tsv"))
    (efi-fixture
     . ,(repo-text
         "tests/fixtures/guix-system-pruning-transaction/efi-sentinel.txt"))))

(assert-equal
 (sort (map car (sk:assert-fused-inputs inputs))
       (lambda (left right)
         (string<? (symbol->string left) (symbol->string right))))
 (sort (list-copy sk:fused-input-labels)
       (lambda (left right)
         (string<? (symbol->string left) (symbol->string right))))
 "closed actual-repository input labels")

(define rendered-a (sk:render-fused-program inputs))
(define rendered-b (sk:render-fused-program (reverse inputs)))

(assert-equal rendered-a rendered-b "input-order independence")
(assert-equal (text-sha256 rendered-a)
              (text-sha256 rendered-b)
              "deterministic whole-source digest")
(assert (string-suffix? "\n" rendered-a)
        "rendered source lacks terminal LF")
(assert (not (string-index rendered-a #\return))
        "rendered source contains CR")
(assert (string-prefix?
         "#!/gnu/store/f75z9sgss74ndiy1jnr02fippk1fjwkj-guile-wrapper/bin/guile --no-auto-compile\n!#\n"
         rendered-a)
        "rendered source lacks the exact Guile shebang")
(let ((unset-index
       (string-contains rendered-a "(unsetenv \"GUILE_LOAD_PATH\")"))
      (runtime-auto-compile-index
       (string-contains
        rendered-a
        "(set! %load-should-auto-compile #f)"))
      (first-module-index
       (string-contains rendered-a "(define-module")))
  (assert (and unset-index
               runtime-auto-compile-index
               first-module-index
               (< unset-index runtime-auto-compile-index)
               (< runtime-auto-compile-index first-module-index))
          "search-path sanitization does not precede every module"))
(for-each
 (lambda (required)
   (assert (string-contains rendered-a required)
           "startup provenance omitted ~a"
           required))
 '("/gnu/store/0m3ynhgibwnxw9pj9lib71mpnwkz71c4-guix-a8391f2d7-modules"
   "/gnu/store/33f7w4fr1cljrzq8czffngcnvrbpf02w-guile-gcrypt-0.5.0"
   "guix/base16.go"
   "gcrypt/hash.go"
   "runtime auto-compile flag is enabled"
   "sk:assert-fused-startup"))

(call-with-output-file rendered-output
  (lambda (port)
    (display rendered-a port)))

(define rendered-forms (source-forms rendered-a))
(define sections (sk:fused-program-sections inputs))
(assert-equal
 (map car sections)
 '(root-backend-source
   boundary-source
   orchestrator-source
   reconciliation-source
   embedded-context-source
   transaction-core-source
   phase-engine-source
   fixture-runtime-source
   embedded-inputs-source
   fused-driver-source)
 "canonical executed section order")

(define %expected-packet-spec
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

(define expected-packets
  (map
   (lambda (spec)
     (let ((source (cdr (assq (car spec) sections))))
       (list (car spec)
             (cadr spec)
             (text-sha256 source)
             (bytevector-length (string->utf8 source))
             source)))
   %expected-packet-spec))

(define expected-identities
  (map (lambda (packet) (take packet 4))
       expected-packets))

(define identities-definition
  (variable-definition-form rendered-forms
                            '%fused-source-identities))
(define packets-definition
  (variable-definition-form rendered-forms
                            '%fused-source-packets))
(assert identities-definition
        "rendered source omits its identity table")
(assert packets-definition
        "rendered source omits its source-packet table")
(define actual-identities (cadr (caddr identities-definition)))
(define actual-packets (cadr (caddr packets-definition)))

(assert-equal
 (take-right rendered-forms 5)
 `((define %fused-source-identities
     ',expected-identities)
   (define %fused-source-packets
     ',expected-packets)
   (define %prepared-fused-sources
     (sk:preflight-fused-sources
      %fused-source-identities
      %fused-source-packets))
   (sk:eval-fused-sources %prepared-fused-sources)
   (sk:invoke-fused-main (cdr (command-line))))
 "closed preflight/eval/main tail")

(assert-equal (length actual-packets) 10 "packet count")
(assert-equal
 (map (lambda (packet) (take packet 2))
      actual-packets)
 %expected-packet-spec
 "packet label/module/order")
(assert-equal actual-identities
              (map (lambda (packet) (take packet 4))
                   actual-packets)
              "packet identities")

(for-each
 (lambda (packet)
   (assert-equal
    (list-ref packet 2)
    (text-sha256 (list-ref packet 4))
    (format #f "packet SHA256: ~a" (car packet)))
   (assert-equal
    (list-ref packet 3)
    (bytevector-length (string->utf8 (list-ref packet 4)))
    (format #f "packet UTF-8 size: ~a" (car packet)))
   (assert-equal
    (list-ref packet 4)
    (cdr (assq (list-ref packet 0) sections))
    (format #f "packet source round-trip: ~a" (car packet))))
 actual-packets)

(for-each
 (lambda (label)
   (assert-equal (cdr (assq label sections))
                 (cdr (assq label inputs))
                 (format #f "exact source preservation: ~a" label)))
 '(root-backend-source
   boundary-source
   orchestrator-source
   reconciliation-source
   embedded-context-source
   transaction-core-source
   phase-engine-source
   fixture-runtime-source
   fused-driver-source))

(define embedded (cdr (assq 'embedded-inputs-source sections)))
(for-each
 (lambda (binding)
   (let ((label (car binding))
         (text (cdr binding)))
     (assert (string-contains embedded (text-sha256 text))
             "embedded identities omitted digest for ~a"
             label)
     (assert
      (string-contains embedded
                       (number->string
                        (bytevector-length (string->utf8 text))))
      "embedded identities omitted size for ~a"
      label)
     (assert
      (string-contains
       embedded
       (bytevector->base16-string (string->utf8 text)))
      "embedded bytes are not exact for ~a"
      label)))
 inputs)

(for-each
 (lambda (path)
   (assert (string-contains embedded path)
           "generated path-to-text closure omitted ~a"
           path))
 '("guix/modules/sk/system-pruning-transaction.scm"
   "guix/modules/sk/system-pruning-root-backend.scm"
   "guix/modules/sk/system-pruning-boundary.scm"
   "guix/modules/sk/system-pruning-orchestrator.scm"
   "guix/modules/sk/system-pruning-reconciliation.scm"
   "guix/modules/sk/system-pruning-embedded-context.scm"
   "guix/modules/sk/system-pruning-phase-engine.scm"
   "guix/modules/sk/system-pruning-fixture-runtime.scm"
   "scripts/guix-system-pruning-fused-driver.scm"
   "scripts/guix-system-pruning-transaction.scm"
   "scripts/guix-system-pruning-transaction"
   "tests/fixtures/guix-system-pruning-transaction/profile-lock-holder.scm"
   "tests/fixtures/guix-system-pruning-transaction/old-grub.cfg"
   "tests/fixtures/guix-system-pruning-transaction/generation-pins.tsv"
   "tests/fixtures/guix-system-pruning-transaction/efi-sentinel.txt"
   "tests/fixtures/guix-system-pruning-transaction/phase-registry.tsv"
   "docs/audits/data/2026-07-19-p5.2b-d2b-retained-grub.cfg"))

;; The renderer emits one startup module and treats every project module as
;; immutable data until all ten packets have passed one closed preflight.
(define program-path-definition
  (variable-definition-form rendered-forms
                            'sk:fused-program-path))
(define prepared-sources-definition
  (variable-definition-form rendered-forms
                            '%prepared-fused-sources))
(define preflight-form
  (definition-form rendered-forms
                   'sk:preflight-fused-sources))
(define read-source-form
  (definition-form rendered-forms
                   'read-source-forms))
(define evaluator-form
  (definition-form rendered-forms
                   'evaluate-prepared-source))
(define invoke-main-form
  (definition-form rendered-forms
                   'sk:invoke-fused-main))
(define eval-action
  '(sk:eval-fused-sources %prepared-fused-sources))
(define main-action
  '(sk:invoke-fused-main (cdr (command-line))))

(for-each
 (lambda (binding)
   (assert (cdr binding)
           "rendered source omits loader form: ~a"
           (car binding)))
 `((program-path . ,program-path-definition)
   (prepared-sources . ,prepared-sources-definition)
   (preflight . ,preflight-form)
   (source-reader . ,read-source-form)
   (evaluator . ,evaluator-form)
   (invoke-main . ,invoke-main-form)))

(assert-equal
 (caddr program-path-definition)
 '(begin
    (sk:assert-fused-startup)
    (assert-fused-program-location))
 "canonical location initializer")
(assert (= (tree-count preflight-form 'eval) 0)
        "preflight contains eval")
(assert (= (tree-count read-source-form 'eval) 0)
        "source parser contains eval")
(assert (= (tree-count preflight-form
                       'evaluate-prepared-source)
           0)
        "preflight calls the evaluator")
(assert (= (tree-count evaluator-form 'eval) 2)
        "evaluator does not contain exactly declaration/body eval")
(assert (= (tree-count rendered-forms 'eval) 2)
        "eval capability exists outside the evaluator")
(assert (= (tree-count read-source-form 'set-port-filename!) 1)
        "source parser does not set one synthetic filename")
(assert (= (tree-count read-source-form 'sk:fused-program-path) 1)
        "source parser does not use the canonical fused filename")
(assert (= (tree-count invoke-main-form 'sk:main) 1)
        "main dispatcher does not perform one sk:main lookup")
(assert (= (subform-count
            invoke-main-form
            (lambda (form)
              (equal? form '(main arguments))))
           1)
        "main dispatcher does not call main exactly once")

(let ((program-path-index
       (form-index rendered-forms program-path-definition))
      (prepared-sources-index
       (form-index rendered-forms prepared-sources-definition))
      (eval-action-index
       (form-index rendered-forms eval-action))
      (main-action-index
       (form-index rendered-forms main-action)))
  (assert (and (integer? program-path-index)
               (integer? prepared-sources-index)
               (integer? eval-action-index)
               (integer? main-action-index)
               (< program-path-index
                  prepared-sources-index
                  eval-action-index
                  main-action-index))
          "canonical-location/preflight/eval/main order drift"))

(assert
 (= 0
    (subform-count
     rendered-forms
     (lambda (form)
       (and (pair? form)
            (eq? (car form) 'define-module)
            (pair? (cdr form))
            (member (cadr form)
                    (map cadr %expected-packet-spec))))))
 "project modules escaped their source packets")
(assert (= 0 (tree-count rendered-forms 'sk:load-fused-source))
        "old interleaved source loader remains")
(for-each
 (lambda (forbidden)
   (assert (= 0 (tree-count rendered-forms forbidden))
           "rendered loader contains repository-read capability: ~a"
           forbidden))
 '(call-with-input-file
   load
   open-input-file
   primitive-load))

;; Closed input shape, exact digest binding, and authorization fail closed.
(for-each
 (lambda (candidate)
   (assert (fails? (lambda () (sk:render-fused-program candidate)))
           "invalid fused inputs were accepted"))
 (list
  (alist-delete 'manifest inputs)
  (cons '(unknown . "unknown\n") inputs)
  (cons (assq 'manifest inputs) inputs)
  (acons 'manifest
         (string-append (cdr (assq 'manifest inputs)) "\n")
         (alist-delete 'manifest inputs))
  (acons 'manifest
         (string-map
          (lambda (character)
            (if (char=? character #\newline) #\return character))
          (cdr (assq 'manifest inputs)))
         (alist-delete 'manifest inputs))
  (acons 'transaction-core-source
         (string-append
          (cdr (assq 'transaction-core-source inputs))
          ";;; drift\n")
         (alist-delete 'transaction-core-source inputs))
  (acons 'crash-registry
         "schema\tunknown\n"
         (alist-delete 'crash-registry inputs))))

(for-each
 (lambda (label)
   (assert
    (fails?
     (lambda ()
       (sk:render-fused-program
        (acons label
               (string-append (cdr (assq label inputs)) ";;; drift\n")
               (alist-delete label inputs)))))
    "manifest-bound executed source drift was accepted: ~a"
    label))
 '(root-backend-source
   boundary-source
   orchestrator-source
   reconciliation-source
   embedded-context-source
   transaction-core-source
   phase-engine-source
   fixture-runtime-source
   fused-driver-source))

;; Keep realization and direct mutation capabilities outside the renderer.
(define renderer-source
  (repo-text "guix/modules/sk/system-pruning-fused-source.scm"))
(define fused-driver-source
  (repo-text "scripts/guix-system-pruning-fused-driver.scm"))
(define fused-driver-forms (source-forms fused-driver-source))
(define d4a-run
  (definition-form fused-driver-forms 'run-d4a-fixture))
(define reconciliation-run
  (definition-form fused-driver-forms 'run-reconciliation))
(define reconciliation-gate
  (definition-form fused-driver-forms
                   'call-with-reconciliation-phase))
(define legacy-run
  (definition-form fused-driver-forms 'run-legacy-fixture))
(define runtime-identity
  (definition-form fused-driver-forms 'assert-runtime-identity))
(define driver-main
  (definition-form fused-driver-forms 'sk:main))

(assert d4a-run "fused driver omits the D4a runtime action boundary")
(assert reconciliation-run
        "fused driver omits the synthetic reconciliation action boundary")
(assert reconciliation-gate
        "fused driver omits the reconciliation central gate")
(assert legacy-run "fused driver omits the explicit legacy action boundary")
(assert driver-main "fused driver omits its inert main boundary")
(assert-equal
 (car (take-right fused-driver-forms 1))
 driver-main
 "driver sk:main definition is last")
(assert (= (tree-count fused-driver-forms 'sk:main) 2)
        "sk:main occurs outside its export and definition")
(assert
 (every
  (lambda (form)
    (and (pair? form)
         (memq (car form) '(define-module define))))
  fused-driver-forms)
 "fused driver has a top-level action")
(assert
 (and runtime-identity
      (pair? (caddr runtime-identity))
      (eq? (car (caddr runtime-identity)) 'let)
      (equal?
       (cadr (car (cadr (caddr runtime-identity))))
       '(canonical-store-program)))
 "canonical store identity is not the first runtime-identity operation")
(assert (> (tree-count d4a-run 'sk:run-fixture-runtime!) 0)
        "D4a actions do not call the real phase-engine runtime")
(assert (= (tree-count d4a-run
                       'sk:run-embedded-fixture-transaction)
           0)
        "D4a actions alias the legacy transaction oracle")
(assert (> (tree-count reconciliation-run
                       'sk:reconcile-synthetic!)
           0)
        "fixture-reconcile does not call the real synthetic reconciler")
(assert (> (tree-count reconciliation-gate
                       'sk:call-with-pre-phase-gate)
           0)
        "synthetic reconciliation bypasses the central phase gate")
(assert (> (tree-count reconciliation-gate 'phase-active?) 0)
        "reconciliation session/quiescence gates omit phase exclusion")
(assert (> (tree-count reconciliation-run 'dynamic-wind) 0)
        "reconciliation effects omit dynamic phase exclusion")
(assert (> (tree-count legacy-run
                       'sk:run-embedded-fixture-transaction)
           0)
        "legacy actions do not retain the reviewed oracle")
(assert (= (tree-count fused-driver-forms
                       'sk:run-embedded-fixture-transaction)
           1)
        "legacy transaction oracle is reachable outside its one boundary")
(assert (= (tree-count fused-driver-forms 'sk:run-fixture-runtime!)
           1)
        "D4a runtime has an unexpected fused-driver call surface")
(assert (= (tree-count fused-driver-forms 'sk:reconcile-synthetic!)
           1)
        "synthetic reconciler has an unexpected fused-driver call surface")

(for-each
 (lambda (forbidden)
   (assert (not (string-contains renderer-source forbidden))
           "renderer source contains forbidden capability: ~a"
           forbidden))
 '("computed-file"
   "lower-object"
   "with-store"
   "open-connection"
   "built-derivations"
   "add-temp-root"
   "rename-file"
   "delete-file"
   "(mkdir"))

(format #t "guix-system-pruning-fused-source-check: PASS~%")
