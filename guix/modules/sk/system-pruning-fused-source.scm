;;; Pure deterministic source renderer for one fused pruning program.

(define-module (sk system-pruning-fused-source)
  #:use-module (gcrypt hash)
  #:use-module (guix base16)
  #:use-module (rnrs bytevectors)
  #:use-module (sk system-pruning-transaction)
  #:use-module (srfi srfi-1)
  #:export (sk:assert-fused-inputs
            sk:fused-input-labels
            sk:fused-program-sections
            sk:render-fused-program))

(define %error-key 'sk-system-pruning-fused-source)

(define %source-labels
  '(root-backend-source
    boundary-source
    orchestrator-source
    reconciliation-source
    embedded-context-source
    transaction-core-source
    phase-engine-source
    fixture-runtime-source
    fused-driver-source))

(define %transaction-path-labels
  '(("guix/modules/sk/system-pruning-root-backend.scm"
     . root-backend-source)
    ("guix/modules/sk/system-pruning-boundary.scm"
     . boundary-source)
    ("guix/modules/sk/system-pruning-orchestrator.scm"
     . orchestrator-source)
    ("guix/modules/sk/system-pruning-reconciliation.scm"
     . reconciliation-source)
    ("guix/modules/sk/system-pruning-embedded-context.scm"
     . embedded-context-source)
    ("guix/modules/sk/system-pruning-transaction.scm"
     . transaction-core-source)
    ("guix/modules/sk/system-pruning-phase-engine.scm"
     . phase-engine-source)
    ("guix/modules/sk/system-pruning-fixture-runtime.scm"
     . fixture-runtime-source)
    ("scripts/guix-system-pruning-fused-driver.scm"
     . fused-driver-source)
    ("scripts/guix-system-pruning-transaction.scm"
     . legacy-driver)
    ("scripts/guix-system-pruning-transaction"
     . legacy-launcher)
    ("tests/fixtures/guix-system-pruning-transaction/profile-lock-holder.scm"
     . profile-lock-holder)
    ("tests/fixtures/guix-system-pruning-transaction/old-grub.cfg"
     . old-grub-fixture)
    ("tests/fixtures/guix-system-pruning-transaction/generation-pins.tsv"
     . pins-fixture)
    ("tests/fixtures/guix-system-pruning-transaction/efi-sentinel.txt"
     . efi-fixture)
    ("tests/fixtures/guix-system-pruning-transaction/phase-registry.tsv"
     . crash-registry)
    ("docs/audits/data/2026-07-19-p5.2b-d2b-retained-grub.cfg"
     . retained-grub)))

(define sk:fused-input-labels
  (append
   %source-labels
   '(manifest
     crash-registry
     retained-grub
     legacy-driver
     legacy-launcher
     profile-lock-holder
     old-grub-fixture
     pins-fixture
     efi-fixture)))

(define (%fail format-string . arguments)
  (throw %error-key (apply format #f format-string arguments)))

(define (ensure condition format-string . arguments)
  (unless condition
    (apply %fail format-string arguments)))

(define (input-entry inputs label)
  (let ((entry (assq label inputs)))
    (ensure entry "fused input is missing: ~a" label)
    entry))

(define (input-text inputs label)
  (cdr (input-entry inputs label)))

(define (string-sha256 value)
  (bytevector->base16-string
   (bytevector-hash
    (string->utf8 value)
    (hash-algorithm sha256))))

(define (utf8-size value)
  (bytevector-length (string->utf8 value)))

(define (line-count text line)
  (count (lambda (candidate) (string=? candidate line))
         (string-split text #\newline)))

(define (assert-text label text)
  (ensure (string? text) "fused input is not text: ~a" label)
  (ensure (not (string-null? text)) "fused input is empty: ~a" label)
  (ensure (not (string-index text #\nul))
          "fused input contains NUL: ~a" label)
  (ensure (not (string-index text #\return))
          "fused input contains CR: ~a" label)
  (ensure (string-suffix? "\n" text)
          "fused input lacks one terminal LF: ~a" label)
  ;; Requiring a non-LF byte immediately before the terminal LF rejects a
  ;; variable number of blank trailing lines without rewriting reviewed bytes.
  (ensure (or (= (string-length text) 1)
              (not (char=? (string-ref text (- (string-length text) 2))
                           #\newline)))
          "fused input has a blank trailing line: ~a" label))

(define (assert-closed-fixture-manifest text)
  (for-each
   (lambda (line)
     (ensure (= (line-count text line) 1)
             "fixture manifest requires exactly one row: ~s"
             line))
   '("schema\tp5.2b-system-prune-transaction/v1"
     "mode\tFIXTURE-ONLY"
     "authorization\tNOT-GRANTED"
     "status\tFIXTURE-ONLY")))

(define (records-with-key records key)
  (filter (lambda (record)
            (and (pair? record) (string=? (car record) key)))
          records))

(define (assert-manifest-input-bindings inputs)
  (let* ((records
          (sk:assert-transaction-manifest
           (sk:read-tsv-string (input-text inputs 'manifest))))
         (implementation
          (records-with-key records "implementation-input"))
         (registry (car (records-with-key records "crash-registry")))
         (grub (car (records-with-key records "new-grub-source")))
         (bindings
          (append
           (map (lambda (record)
                  (list (list-ref record 2)
                        (list-ref record 3)))
                implementation)
           (list
            (list (list-ref registry 1)
                  (list-ref registry 2))
            (list (list-ref grub 1)
                  (list-ref grub 2))))))
    (ensure (= (length bindings) (length %transaction-path-labels))
            "manifest input count differs from the fused path map")
    (for-each
     (lambda (binding)
       (let* ((path (car binding))
              (expected (cadr binding))
              (mapping (assoc path %transaction-path-labels)))
         (ensure mapping
                 "manifest path is absent from the fused path map: ~a"
                 path)
         (ensure
          (string=?
           (string-sha256 (input-text inputs (cdr mapping)))
           expected)
          "fused input SHA256 differs from manifest: ~a"
          path)))
     bindings)
    (for-each
     (lambda (mapping)
       (ensure (assoc (car mapping) bindings)
               "fused path map is absent from manifest: ~a"
               (car mapping)))
     %transaction-path-labels)
    (ensure
     (= (utf8-size (input-text inputs 'retained-grub))
        (string->number (list-ref grub 3) 10))
     "retained GRUB size differs from manifest")))

(define (assert-closed-crash-registry text)
  (ensure
   (= (line-count text
                  "schema\tp5.2b-system-prune-crash-registry/v1")
      1)
   "crash registry has no unique accepted schema"))

(define (sk:assert-fused-inputs inputs)
  "Validate INPUTS as the closed set of text used by the pure renderer.

INPUTS is an association list whose labels must equal
`sk:fused-input-labels'.  Every value is preserved byte-for-byte as UTF-8."
  (ensure (list? inputs) "fused inputs are not a proper list")
  (for-each
   (lambda (entry)
     (ensure (and (pair? entry)
                  (symbol? (car entry))
                  (string? (cdr entry)))
             "fused input entry has an invalid shape: ~s"
             entry))
   inputs)
  (let ((labels (map car inputs)))
    (ensure (= (length labels) (length (delete-duplicates labels)))
            "fused inputs contain duplicate labels")
    (ensure (= (length labels) (length sk:fused-input-labels))
            "fused input count differs from the closed contract")
    (ensure (every (lambda (label) (memq label labels))
                   sk:fused-input-labels)
            "fused inputs omit a required label")
    (ensure (every (lambda (label) (memq label sk:fused-input-labels))
                   labels)
            "fused inputs contain an unknown label"))
  (for-each
   (lambda (label)
     (assert-text label (input-text inputs label)))
   sk:fused-input-labels)
  (assert-closed-fixture-manifest (input-text inputs 'manifest))
  (assert-closed-crash-registry (input-text inputs 'crash-registry))
  (assert-manifest-input-bindings inputs)
  inputs)

(define (input-identity inputs label)
  (let ((text (input-text inputs label)))
    (list label
          (string-sha256 text)
          (utf8-size text))))

(define (input-hex inputs label)
  (bytevector->base16-string
   (string->utf8 (input-text inputs label))))

(define (write-generated-embedded-module inputs port)
  (let ((identities
         (map (lambda (label) (input-identity inputs label))
              sk:fused-input-labels))
        (payloads
         (map (lambda (label)
                (cons label (input-hex inputs label)))
              sk:fused-input-labels)))
    (display
     ";;; Generated immutable payload; do not edit.\n\n"
     port)
    (display
     "(define-module (sk system-pruning-embedded-inputs)\n"
     port)
    (display
     "  #:use-module (guix base16)\n"
     port)
    (display
     "  #:use-module (rnrs bytevectors)\n"
     port)
    (display
     "  #:export (sk:embedded-input-bytevector\n"
     port)
    (display
     "            sk:embedded-input-identities\n"
     port)
    (display
     "            sk:embedded-input-string\n"
     port)
    (display
     "            sk:embedded-manifest-bytes\n"
     port)
    (display
     "            sk:embedded-manifest-sha256\n"
     port)
    (display
     "            sk:embedded-transaction-inputs))\n\n"
     port)
    (display "(define sk:embedded-input-identities\n  '" port)
    (write identities port)
    (display ")\n\n" port)
    (display "(define sk:embedded-manifest-sha256\n  " port)
    (write (string-sha256 (input-text inputs 'manifest)) port)
    (display ")\n\n" port)
    (display "(define %embedded-transaction-path-labels\n  '" port)
    (write %transaction-path-labels port)
    (display ")\n\n" port)
    (display "(define %embedded-payload-hex\n  '" port)
    (write payloads port)
    (display ")\n\n" port)
    (display
     "(define (payload-hex label)\n"
     port)
    (display
     "  (let ((entry (assq label %embedded-payload-hex)))\n"
     port)
    (display
     "    (unless entry\n"
     port)
    (display
     "      (error \"unknown embedded pruning payload\" label))\n"
     port)
    (display
     "    (cdr entry)))\n\n"
     port)
    (display
     "(define (sk:embedded-input-bytevector label)\n"
     port)
    (display
     "  (base16-string->bytevector (payload-hex label)))\n\n"
     port)
    (display
     "(define (sk:embedded-input-string label)\n"
     port)
    (display
     "  (utf8->string (sk:embedded-input-bytevector label)))\n"
     port)
    (display
     "\n(define sk:embedded-manifest-bytes\n"
     port)
    (display
     "  (sk:embedded-input-bytevector 'manifest))\n"
     port)
    (display
     "\n(define sk:embedded-transaction-inputs\n"
     port)
    (display
     "  (map (lambda (binding)\n"
     port)
    (display
     "         (cons (car binding)\n"
     port)
    (display
     "               (sk:embedded-input-string (cdr binding))))\n"
     port)
    (display
     "       %embedded-transaction-path-labels))\n"
     port)))

(define %guile-program
  "/gnu/store/f75z9sgss74ndiy1jnr02fippk1fjwkj-guile-wrapper/bin/guile")

(define %guile-load-path
  '("/gnu/store/0m3ynhgibwnxw9pj9lib71mpnwkz71c4-guix-a8391f2d7-modules/share/guile/site/3.0"
    "/gnu/store/2p4vnz9y2ndfsbary431rzlf41jhanrs-profile/share/guile/site/3.0"
    "/gnu/store/z84fzavdzq9ja3lyln3cf9px4h45ybf9-profile/share/guile/site/3.0"
    "/gnu/store/8vwbdsni9znrlxvcwqi4n02f23ysc1fa-guile-3.0.11/share/guile/3.0"
    "/gnu/store/8vwbdsni9znrlxvcwqi4n02f23ysc1fa-guile-3.0.11/share/guile/site/3.0"
    "/gnu/store/8vwbdsni9znrlxvcwqi4n02f23ysc1fa-guile-3.0.11/share/guile/site"
    "/gnu/store/8vwbdsni9znrlxvcwqi4n02f23ysc1fa-guile-3.0.11/share/guile"))

(define %guile-compiled-path
  '("/gnu/store/0m3ynhgibwnxw9pj9lib71mpnwkz71c4-guix-a8391f2d7-modules/lib/guile/3.0/site-ccache"
    "/gnu/store/2p4vnz9y2ndfsbary431rzlf41jhanrs-profile/lib/guile/3.0/site-ccache"
    "/gnu/store/z84fzavdzq9ja3lyln3cf9px4h45ybf9-profile/lib/guile/3.0/site-ccache"
    "/gnu/store/8vwbdsni9znrlxvcwqi4n02f23ysc1fa-guile-3.0.11/lib/guile/3.0/ccache"
    "/gnu/store/8vwbdsni9znrlxvcwqi4n02f23ysc1fa-guile-3.0.11/lib/guile/3.0/site-ccache"))

(define %guile-extensions-path
  "/gnu/store/z84fzavdzq9ja3lyln3cf9px4h45ybf9-profile/lib/guile/3.0/extensions")

(define %guix-base16-source
  "/gnu/store/0m3ynhgibwnxw9pj9lib71mpnwkz71c4-guix-a8391f2d7-modules/share/guile/site/3.0/guix/base16.scm")

(define %gcrypt-hash-source
  "/gnu/store/33f7w4fr1cljrzq8czffngcnvrbpf02w-guile-gcrypt-0.5.0/share/guile/site/3.0/gcrypt/hash.scm")

(define %guix-base16-compiled
  "/gnu/store/0m3ynhgibwnxw9pj9lib71mpnwkz71c4-guix-a8391f2d7-modules/lib/guile/3.0/site-ccache/guix/base16.go")

(define %gcrypt-hash-compiled
  "/gnu/store/33f7w4fr1cljrzq8czffngcnvrbpf02w-guile-gcrypt-0.5.0/lib/guile/3.0/site-ccache/gcrypt/hash.go")

(define %startup-loader-forms
  '((define %loader-module (current-module))
    (define %loader-root-module
      (resolve-module '() #f #:ensure #f))
    (define %store-alphabet
      "0123456789abcdfghijklmnpqrsvwxyz")
    (define %store-suffix "-system-pruning-loaded.scm")
    (define %canonical-fused-section-spec
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
    (define (all? predicate values)
      (let loop ((rest values))
        (or (null? rest)
            (and (predicate (car rest))
                 (loop (cdr rest))))))
    (define (contains-character? text character)
      (let loop ((index 0))
        (and (< index (string-length text))
             (or (char=? (string-ref text index) character)
                 (loop (+ index 1))))))
    (define (valid-module-name? name)
      (and (list? name)
           (not (null? name))
           (all? symbol? name)))
    (define (valid-digest? digest)
      (and (string? digest)
           (= (string-length digest) 64)
           (all?
            (lambda (character)
              (contains-character? "0123456789abcdef" character))
            (string->list digest))))
    (define (canonical-source-text? source)
      (and (string? source)
           (> (string-length source) 0)
           (char=? (string-ref source
                              (- (string-length source) 1))
                   #\newline)
           (not (contains-character? source #\nul))
           (not (contains-character? source #\return))))
    (define (source-sha256 source)
      (bytevector->base16-string
       (bytevector-hash
        (string->utf8 source)
        (hash-algorithm sha256))))
    (define (source-size source)
      (bytevector-length (string->utf8 source)))
    (define (store-hash? text)
      (and (= (string-length text) 32)
           (all?
            (lambda (character)
              (contains-character? %store-alphabet character))
            (string->list text))))
    (define (assert-fused-program-location)
      (let ((source (current-filename)))
        (startup-ensure
         (and source (absolute-file-name? source))
         "fused program filename is not absolute")
        (startup-ensure
         (eq? 'regular (stat:type (lstat source)))
         "fused program is not a regular file")
        (let ((canonical
               (false-if-exception (canonicalize-path source))))
          (startup-ensure
           (and canonical (string=? source canonical))
           "fused program filename is not canonical"))
        (startup-ensure
         (string=? (dirname source) "/gnu/store")
         "fused program is outside the canonical store directory")
        (let* ((name (basename source))
               (suffix-length (string-length %store-suffix)))
          (startup-ensure
           (= (string-length name) (+ 32 suffix-length))
           "fused program store name has the wrong length")
          (startup-ensure
           (store-hash? (substring name 0 32))
           "fused program store hash is invalid")
          (startup-ensure
           (string=? (substring name 32) %store-suffix)
           "fused program store suffix is invalid"))
        (let ((metadata (lstat source)))
          (startup-ensure
           (= (stat:uid metadata) 0)
           "fused program is not owned by root")
          (startup-ensure
           (zero? (logand (stat:perms metadata) #o222))
           "fused program is writable"))
        source))
    (define sk:fused-program-path
      (begin
        (sk:assert-fused-startup)
        (assert-fused-program-location)))
    (define (project-module name)
      (nested-ref-module %loader-root-module name))
    (define (module-declaration? form)
      (and (pair? form)
           (eq? (car form) 'define-module)))
    (define (read-source-forms label expected-module source)
      (let ((port (open-input-string source)))
        (set-port-filename! port sk:fused-program-path)
        (let loop ((forms '()))
          (let ((form (read port)))
            (if (eof-object? form)
                (let ((ordered (reverse forms)))
                  (startup-ensure
                   (pair? ordered)
                   "fused source has no forms")
                  (startup-ensure
                   (and (list? (car ordered))
                        (>= (length (car ordered)) 2)
                        (eq? (caar ordered) 'define-module)
                        (equal? (cadar ordered) expected-module))
                   "fused source has another declared module")
                  (startup-ensure
                   (pair? (cdr ordered))
                   "fused module body is empty")
                  (startup-ensure
                   (all?
                    (lambda (candidate)
                      (not (module-declaration? candidate)))
                    (cdr ordered))
                   "fused module body changes module")
                  (list label expected-module ordered))
                (loop (cons form forms)))))))
    (define (packet-shape? packet)
      (and (list? packet)
           (= (length packet) 5)
           (symbol? (list-ref packet 0))
           (valid-module-name? (list-ref packet 1))
           (valid-digest? (list-ref packet 2))
           (integer? (list-ref packet 3))
           (>= (list-ref packet 3) 0)
           (canonical-source-text? (list-ref packet 4))))
    (define (identity-shape? identity)
      (and (list? identity)
           (= (length identity) 4)
           (symbol? (list-ref identity 0))
           (valid-module-name? (list-ref identity 1))
           (valid-digest? (list-ref identity 2))
           (integer? (list-ref identity 3))
           (>= (list-ref identity 3) 0)))
    (define (packet-spec packet)
      (list (list-ref packet 0)
            (list-ref packet 1)))
    (define (packet-identity packet)
      (list (list-ref packet 0)
            (list-ref packet 1)
            (list-ref packet 2)
            (list-ref packet 3)))
    (define (sk:preflight-fused-sources expected-identities packets)
      (sk:assert-fused-startup)
      (startup-ensure
       (and (list? expected-identities)
            (= (length expected-identities)
               (length %canonical-fused-section-spec))
            (all? identity-shape? expected-identities))
       "fused source identities have an invalid shape")
      (startup-ensure
       (and (list? packets)
            (= (length packets)
               (length %canonical-fused-section-spec))
            (all? packet-shape? packets))
       "fused source packets have an invalid shape")
      (startup-ensure
       (equal? (map packet-spec packets)
               %canonical-fused-section-spec)
       "fused source packet order or module identity drift")
      (startup-ensure
       (equal? expected-identities
               (map packet-identity packets))
       "fused source packet identities drift")
      (for-each
       (lambda (packet)
         (let ((expected-sha (list-ref packet 2))
               (expected-size (list-ref packet 3))
               (source (list-ref packet 4)))
           (startup-ensure
            (string=? (source-sha256 source) expected-sha)
            "fused source packet SHA256 drift")
           (startup-ensure
            (= (source-size source) expected-size)
            "fused source packet UTF-8 size drift")))
       packets)
      (let ((prepared
             (map
              (lambda (packet)
                (read-source-forms
                 (list-ref packet 0)
                 (list-ref packet 1)
                 (list-ref packet 4)))
              packets)))
        (for-each
         (lambda (spec)
           (startup-ensure
            (not (project-module (cadr spec)))
            "fused project module already exists"))
         %canonical-fused-section-spec)
        prepared))
    (define (evaluate-prepared-source prepared)
      (let ((label (list-ref prepared 0))
            (expected-module (list-ref prepared 1))
            (forms (list-ref prepared 2))
            (previous (current-module)))
        (dynamic-wind
          (lambda ()
            (set-current-module %loader-module))
          (lambda ()
            (startup-ensure
             (not (project-module expected-module))
             "fused project module appeared before evaluation")
            (let ((target (eval (car forms) %loader-module)))
              (startup-ensure
               (and (module? target)
                    (equal? (module-name target) expected-module)
                    (eq? target (project-module expected-module)))
               "evaluated fused module identity drift")
              (set-current-module target)
              (for-each
               (lambda (form)
                 (eval form target))
               (cdr forms))
              (startup-ensure
               (eq? target (project-module expected-module))
               "fused module registry identity changed")
              label))
          (lambda ()
            (set-current-module previous)))))
    (define (sk:eval-fused-sources prepared)
      (startup-ensure
       (and (list? prepared)
            (equal?
             (map
              (lambda (entry)
                (list (list-ref entry 0)
                      (list-ref entry 1)))
              prepared)
             %canonical-fused-section-spec))
       "prepared fused source order or identity drift")
      (for-each evaluate-prepared-source prepared)
      #t)
    (define (sk:invoke-fused-main arguments)
      (let* ((interface
              (false-if-exception
               (resolve-interface
                '(sk system-pruning-fused-driver))))
             (main
              (and interface
                   (module-ref interface 'sk:main))))
        (startup-ensure
         (procedure? main)
         "fused driver main is unavailable")
        (main arguments)))))

(define (write-startup-prologue port)
  ;; This code executes before the first external module import in the fused
  ;; file.  Inherited search paths are removed and replaced with immutable,
  ;; reviewed Guile/Guix closure paths.
  (format port "#!~a --no-auto-compile~%!#~%" %guile-program)
  (display "(unsetenv \"GUILE_LOAD_PATH\")\n" port)
  (display "(unsetenv \"GUILE_LOAD_COMPILED_PATH\")\n" port)
  (display "(unsetenv \"GUILE_EXTENSIONS_PATH\")\n" port)
  (display "(setenv \"GUILE_AUTO_COMPILE\" \"0\")\n" port)
  ;; Guile reads GUILE_AUTO_COMPILE before this source starts.  Changing only
  ;; the environment would leave the already-initialized runtime flag true
  ;; when a hostile parent supplied GUILE_AUTO_COMPILE=1.
  (display "(set! %load-should-auto-compile #f)\n" port)
  (display "(setenv \"GUILE_EXTENSIONS_PATH\" " port)
  (write %guile-extensions-path port)
  (display ")\n" port)
  (display "(set! %load-path '" port)
  (write %guile-load-path port)
  (display ")\n" port)
  (display "(set! %load-compiled-path '" port)
  (write %guile-compiled-path port)
  (display ")\n\n" port)
  (display "(define-module (sk system-pruning-startup)\n" port)
  (display "  #:use-module (gcrypt hash)\n" port)
  (display "  #:use-module (guix base16)\n" port)
  (display "  #:use-module (rnrs bytevectors)\n" port)
  (display "  #:export (sk:assert-fused-startup\n" port)
  (display "            sk:eval-fused-sources\n" port)
  (display "            sk:fused-program-path\n" port)
  (display "            sk:preflight-fused-sources))\n\n" port)
  (display "(define %expected-load-path '" port)
  (write %guile-load-path port)
  (display ")\n" port)
  (display "(define %expected-compiled-path '" port)
  (write %guile-compiled-path port)
  (display ")\n" port)
  (display "(define %expected-extensions-path " port)
  (write %guile-extensions-path port)
  (display ")\n" port)
  (display "(define %expected-guile-program " port)
  (write %guile-program port)
  (display ")\n" port)
  (display "(define %expected-guix-base16-source " port)
  (write %guix-base16-source port)
  (display ")\n" port)
  (display "(define %expected-gcrypt-hash-source " port)
  (write %gcrypt-hash-source port)
  (display ")\n" port)
  (display "(define %expected-guix-base16-compiled " port)
  (write %guix-base16-compiled port)
  (display ")\n" port)
  (display "(define %expected-gcrypt-hash-compiled " port)
  (write %gcrypt-hash-compiled port)
  (display ")\n\n" port)
  (display
   "(define (startup-ensure condition message)\n"
   port)
  (display
   "  (unless condition (error \"fused startup provenance failure\" message)))\n\n"
   port)
  (display
   "(define (canonical-search path relative)\n"
   port)
  (display "  (let ((found (search-path path relative)))\n" port)
  (display
   "    (and found (false-if-exception (canonicalize-path found)))))\n\n"
   port)
  (display
   "(define (sk:assert-fused-startup)\n"
   port)
  (display
   "  (startup-ensure (equal? %load-path %expected-load-path)\n"
   port)
  (display "                  \"effective source path drift\")\n" port)
  (display
   "  (startup-ensure (equal? %load-compiled-path %expected-compiled-path)\n"
   port)
  (display "                  \"effective compiled path drift\")\n" port)
  (display
   "  (startup-ensure (eq? %load-should-auto-compile #f)\n"
   port)
  (display "                  \"runtime auto-compile flag is enabled\")\n" port)
  (display
   "  (startup-ensure (string=? (or (getenv \"GUILE_AUTO_COMPILE\") \"\") \"0\")\n"
   port)
  (display "                  \"auto-compile environment drift\")\n" port)
  (display
   "  (startup-ensure (not (getenv \"GUILE_LOAD_PATH\"))\n"
   port)
  (display "                  \"source environment survived sanitization\")\n" port)
  (display
   "  (startup-ensure (not (getenv \"GUILE_LOAD_COMPILED_PATH\"))\n"
   port)
  (display "                  \"compiled environment survived sanitization\")\n" port)
  (display
   "  (startup-ensure\n"
   port)
  (display
   "   (string=? (or (getenv \"GUILE_EXTENSIONS_PATH\") \"\")\n"
   port)
  (display "             %expected-extensions-path)\n" port)
  (display "   \"extension path drift\")\n" port)
  (display
   "  (startup-ensure\n"
   port)
  (display
   "   (string=? (or (false-if-exception (canonicalize-path \"/proc/self/exe\")) \"\")\n"
   port)
  (display "             %expected-guile-program)\n" port)
  (display "   \"Guile executable drift\")\n" port)
  (display
   "  (startup-ensure\n"
   port)
  (display
   "   (string=? (or (canonical-search %load-path \"guix/base16.scm\") \"\")\n"
   port)
  (display "             %expected-guix-base16-source)\n" port)
  (display "   \"Guix module provenance drift\")\n" port)
  (display
   "  (startup-ensure\n"
   port)
  (display
   "   (string=? (or (canonical-search %load-path \"gcrypt/hash.scm\") \"\")\n"
   port)
  (display "             %expected-gcrypt-hash-source)\n" port)
  (display "   \"Guile-Gcrypt module provenance drift\")\n" port)
  (display
   "  (startup-ensure\n"
   port)
  (display
   "   (string=? (or (canonical-search %load-compiled-path \"guix/base16.go\") \"\")\n"
   port)
  (display "             %expected-guix-base16-compiled)\n" port)
  (display "   \"Guix compiled-module provenance drift\")\n" port)
  (display
   "  (startup-ensure\n"
   port)
  (display
   "   (string=? (or (canonical-search %load-compiled-path \"gcrypt/hash.go\") \"\")\n"
   port)
  (display "             %expected-gcrypt-hash-compiled)\n" port)
  (display "   \"Guile-Gcrypt compiled-module provenance drift\")\n" port)
  (display "  #t)\n\n" port)
  (for-each
   (lambda (form)
     (write form port)
     (newline port)
     (newline port))
   %startup-loader-forms))

(define %section-module-names
  '((root-backend-source . (sk system-pruning-root-backend))
    (boundary-source . (sk system-pruning-boundary))
    (orchestrator-source . (sk system-pruning-orchestrator))
    (reconciliation-source . (sk system-pruning-reconciliation))
    (embedded-context-source . (sk system-pruning-embedded-context))
    (transaction-core-source . (sk system-pruning-transaction))
    (phase-engine-source . (sk system-pruning-phase-engine))
    (fixture-runtime-source . (sk system-pruning-fixture-runtime))
    (embedded-inputs-source . (sk system-pruning-embedded-inputs))
    (fused-driver-source . (sk system-pruning-fused-driver))))

(define (sk:fused-program-sections inputs)
  "Return the canonical labeled text sections used by the fused renderer."
  (sk:assert-fused-inputs inputs)
  (list
   (cons 'root-backend-source
         (input-text inputs 'root-backend-source))
   (cons 'boundary-source
         (input-text inputs 'boundary-source))
   (cons 'orchestrator-source
         (input-text inputs 'orchestrator-source))
   (cons 'reconciliation-source
         (input-text inputs 'reconciliation-source))
   (cons 'embedded-context-source
         (input-text inputs 'embedded-context-source))
   (cons 'transaction-core-source
         (input-text inputs 'transaction-core-source))
   (cons 'phase-engine-source
         (input-text inputs 'phase-engine-source))
   (cons 'fixture-runtime-source
         (input-text inputs 'fixture-runtime-source))
   (cons 'embedded-inputs-source
         (call-with-output-string
           (lambda (port)
             (write-generated-embedded-module inputs port))))
   (cons 'fused-driver-source
         (input-text inputs 'fused-driver-source))))

(define (section-identity section)
  (let* ((label (car section))
         (source (cdr section))
         (mapping (assq label %section-module-names)))
    (ensure mapping "fused section has no declared module: ~a" label)
    (list label
          (cdr mapping)
          (string-sha256 source)
          (utf8-size source))))

(define (section-packet section)
  (append (section-identity section)
          (list (cdr section))))

(define (sk:render-fused-program inputs)
  "Render INPUTS deterministically as one Scheme source string.

This pure function neither writes nor realizes its result.  D4b owns any
future immutable-output construction."
  (let* ((sections (sk:fused-program-sections inputs))
         (identities (map section-identity sections))
         (packets (map section-packet sections)))
    (call-with-output-string
      (lambda (port)
        (write-startup-prologue port)
        (display ";;; Deterministic fused System-pruning fixture program.\n"
                 port)
        (display
         ";;; Mode: FIXTURE-ONLY; authorization: NOT-GRANTED.\n"
         port)
        (display
         ";;; Every source packet is verified and parsed before module evaluation.\n\n"
         port)
        (display "(define %fused-source-identities\n  '" port)
        (write identities port)
        (display ")\n\n" port)
        (display "(define %fused-source-packets\n  '" port)
        (write packets port)
        (display ")\n\n" port)
        (display
         "(define %prepared-fused-sources\n  (sk:preflight-fused-sources\n"
         port)
        (display
         "   %fused-source-identities\n   %fused-source-packets))\n\n"
         port)
        (display
         "(sk:eval-fused-sources %prepared-fused-sources)\n\n"
         port)
        (display
         "(sk:invoke-fused-main (cdr (command-line)))\n"
         port)))))
