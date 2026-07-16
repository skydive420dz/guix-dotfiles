(use-modules (guix-disk-health)
             (ice-9 format)
             (ice-9 textual-ports)
             (json)
             (srfi srfi-1)
             (srfi srfi-13))

(define %fixture-path
  (if (> (length (command-line)) 1)
      (list-ref (command-line) 1)
      (error "missing fixture path")))

(define (read-file path)
  (call-with-input-file path get-string-all))

(define %fixture-source (read-file %fixture-path))
(define %fixture
  (json-string->scm %fixture-source #:ordered #t))

(define (object-ref object key)
  (let ((entry (and (list? object) (assoc key object))))
    (if entry
        (cdr entry)
        (error "fixture key is missing" key))))

(define %fixture-version (object-ref %fixture "fixture_version"))
(define %fixture-now (object-ref %fixture "now_epoch"))
(define %drive-response (object-ref %fixture "drive"))
(define %property-responses (object-ref %fixture "properties"))
(define %attribute-response (object-ref %fixture "attributes"))
(define %drive-path
  (object-ref
   (vector-ref (object-ref %drive-response "data") 0)
   "data"))

(define %service "org.freedesktop.UDisks2")
(define %block-path "/org/freedesktop/UDisks2/block_devices/sda")
(define %properties-interface "org.freedesktop.DBus.Properties")
(define %block-interface "org.freedesktop.UDisks2.Block")
(define %ata-interface "org.freedesktop.UDisks2.Drive.Ata")
(define %property-limit 4096)
(define %attribute-limit (* 128 1024))
(define %property-names
  '("SmartSupported"
    "SmartEnabled"
    "SmartUpdated"
    "SmartFailing"
    "SmartPowerOnSeconds"
    "SmartTemperature"
    "SmartNumAttributesFailing"
    "SmartNumAttributesFailedInThePast"
    "SmartNumBadSectors"
    "SmartSelftestStatus"
    "SmartSelftestPercentRemaining"))

(define %checks 0)
(define %failures 0)

(define (check condition label)
  (set! %checks (+ %checks 1))
  (unless condition
    (set! %failures (+ %failures 1))
    (format (current-error-port) "FAIL: ~a~%" label)))

(define (check-equal actual expected label)
  (check (equal? actual expected) label))

(define (contains? haystack needle)
  (and (string? haystack)
       (string? needle)
       (string-contains haystack needle)
       #t))

(define (safe-json payload)
  (catch #t
    (lambda () (json-string->scm payload #:ordered #t))
    (lambda _ #f)))

(define (variant-response signature value)
  `(("type" . "v")
    ("data" . ,(vector
                 `(("type" . ,signature)
                   ("data" . ,value))))))

(define (raw-response payload)
  (cons 'raw payload))

(define (raw-response? response)
  (and (pair? response)
       (eq? (car response) 'raw)
       (string? (cdr response))))

(define (response-payload response)
  (if (raw-response? response)
      (cdr response)
      (string-append (scm->json-string response) "\n")))

(define (policy-option policy)
  (if (eq? policy 'cached-only)
      "--auto-start=no"
      "--auto-start=yes"))

(define (command-prefix policy)
  (list "--system"
        "--json=short"
        "--no-pager"
        "--expect-reply=yes"
        (policy-option policy)
        "--allow-interactive-authorization=no"
        "--timeout=5s"
        "call"))

(define (block-command policy)
  (append (command-prefix policy)
          (list %service
                %block-path
                %properties-interface
                "Get"
                "ss"
                %block-interface
                "Drive")))

(define (property-command policy property)
  (append (command-prefix policy)
          (list %service
                %drive-path
                %properties-interface
                "Get"
                "ss"
                %ata-interface
                property)))

(define (attribute-command policy)
  (append (command-prefix policy)
          (list %service
                %drive-path
                %ata-interface
                "SmartGetAttributes"
                "a{sv}"
                "0")))

(define (expected-arguments policy attributes?)
  (append (list (block-command policy))
          (map (lambda (property) (property-command policy property))
               %property-names)
          (if attributes?
              (list (attribute-command policy))
              '())))

(define (expected-limits attributes?)
  (append (make-list (+ 1 (length %property-names)) %property-limit)
          (if attributes? (list %attribute-limit) '())))

(define (override-ref overrides name fallback)
  (let ((entry (assoc name overrides)))
    (if entry (cdr entry) fallback)))

;; State slot 0 contains (argv . limit) entries in reverse order.  Slot 1
;; contains identifier-free fake-runner diagnostics.  The runner never invokes
;; a subprocess and rejects every command outside the exact allowlist.
(define* (make-fixture-runner policy
                              #:key
                              (drive-response %drive-response)
                              (property-overrides '())
                              (attributes-response %attribute-response))
  (let ((state (vector '() '())))
    (values
     (lambda (arguments maximum-bytes)
       (vector-set! state 0
                    (cons (cons arguments maximum-bytes)
                          (vector-ref state 0)))
       (let* ((property-entries
               (map
                (lambda (name)
                  (cons
                   (property-command policy name)
                   (override-ref property-overrides
                                 name
                                 (object-ref %property-responses name))))
                %property-names))
              (property-entry
               (find (lambda (entry) (equal? arguments (car entry)))
                     property-entries))
              (response
               (cond
                ((equal? arguments (block-command policy)) drive-response)
                (property-entry (cdr property-entry))
                ((equal? arguments (attribute-command policy))
                 attributes-response)
                (else #f))))
         (if response
             (sk:make-command-result 'ok (response-payload response))
             (begin
               (vector-set! state 1
                            (cons 'unexpected-command (vector-ref state 1)))
               (sk:make-command-result 'transport-failed "")))))
     state)))

(define (state-calls state)
  (if state (reverse (vector-ref state 0)) '()))

(define (state-errors state)
  (if state (reverse (vector-ref state 1)) '()))

(define (execute-with-runner arguments runner now state)
  (let ((output (open-output-string))
        (error-output (open-output-string)))
    (let ((status
           (sk:disk-health-run arguments runner now output error-output)))
      (vector status
              (get-output-string output)
              (get-output-string error-output)
              (state-calls state)
              (state-errors state)))))

(define* (execute arguments policy now
                  #:key
                  (drive-response %drive-response)
                  (property-overrides '())
                  (attributes-response %attribute-response))
  (call-with-values
      (lambda ()
        (make-fixture-runner
         policy
         #:drive-response drive-response
         #:property-overrides property-overrides
         #:attributes-response attributes-response))
    (lambda (runner state)
      (execute-with-runner arguments runner now state))))

(define (result-status result) (vector-ref result 0))
(define (result-output result) (vector-ref result 1))
(define (result-error result) (vector-ref result 2))
(define (result-calls result) (vector-ref result 3))
(define (result-errors result) (vector-ref result 4))
(define (result-arguments result) (map car (result-calls result)))
(define (result-limits result) (map cdr (result-calls result)))

(define (vector-set-copy vector index value)
  (let ((copy (list->vector (vector->list vector))))
    (vector-set! copy index value)
    copy))

(define (attribute-tuples response)
  (vector-ref (object-ref response "data") 0))

(define (attributes-with-tuples tuples)
  `(("type" . "a(ysqiiixia{sv})")
    ("data" . ,(vector tuples))))

(define (mutate-attribute response tuple-index field-index value)
  (let* ((tuples (attribute-tuples response))
         (tuple (vector-ref tuples tuple-index))
         (new-tuple (vector-set-copy tuple field-index value))
         (new-tuples (vector-set-copy tuples tuple-index new-tuple)))
    (attributes-with-tuples new-tuples)))

(define (drop-last-attribute response)
  (let* ((tuples (vector->list (attribute-tuples response)))
         (shorter (reverse (cdr (reverse tuples)))))
    (attributes-with-tuples (list->vector shorter))))

(define (duplicate-first-attribute response)
  (let* ((tuples (attribute-tuples response))
         (last-index (- (vector-length tuples) 1)))
    (attributes-with-tuples
     (vector-set-copy tuples last-index (vector-ref tuples 0)))))

(define (calls-obey-allowlist? calls policy)
  (every
   (lambda (arguments)
     (and (list? arguments)
          (>= (length arguments) 14)
          (equal? (take arguments 8) (command-prefix policy))
          (string=? (list-ref arguments 8) %service)
          (let ((method (list-ref arguments 11)))
            (cond
             ((string=? method "Get")
              (and (= (length arguments) 15)
                   (string=? (list-ref arguments 10)
                             %properties-interface)
                   (string=? (list-ref arguments 12) "ss")
                   (or
                    (and (string=? (list-ref arguments 9) %block-path)
                         (string=? (list-ref arguments 13)
                                   %block-interface)
                         (string=? (list-ref arguments 14) "Drive"))
                    (and (string=? (list-ref arguments 9) %drive-path)
                         (string=? (list-ref arguments 13) %ata-interface)
                         (member (list-ref arguments 14)
                                 %property-names)))))
             ((string=? method "SmartGetAttributes")
              (and (= (length arguments) 14)
                   (string=? (list-ref arguments 9) %drive-path)
                   (string=? (list-ref arguments 10) %ata-interface)
                   (string=? (list-ref arguments 12) "a{sv}")
                   (string=? (list-ref arguments 13) "0")))
             (else #f)))))
   calls))

(define (check-safe-result result label)
  (let ((rendered (string-append (result-output result)
                                 (result-error result))))
    (check (sk:privacy-safe? rendered)
           (string-append label ": rendered result is not privacy-safe"))
    (check (not (contains? rendered %drive-path))
           (string-append label ": rendered result contains private path"))))

(define (check-json-classification result expected label)
  (let ((decoded (safe-json (result-output result))))
    (check-equal (result-status result) 0
                 (string-append label ": exit status"))
    (check decoded (string-append label ": JSON parses"))
    (when decoded
      (check-equal (object-ref decoded "classification") expected
                   (string-append label ": classification")))
    (check-safe-result result label)))

;; Fixture invariants.
(check-equal %fixture-version 1 "fixture schema version")
(check (not (contains? (string-downcase %fixture-source) "serial"))
       "healthy fixture contains a serial field")
(check (not (contains? (string-downcase %fixture-source) "wwn"))
       "healthy fixture contains a WWN field")
(define command-result-probe (sk:make-command-result 'ok "synthetic\n"))
(check-equal (sk:command-result-kind command-result-probe) 'ok
             "command-result kind accessor")
(check-equal (sk:command-result-stdout command-result-probe) "synthetic\n"
             "command-result stdout accessor")

;; Exercise the real bounded child transport using this same Guile executable.
;; These probes spawn Guile only; no busctl or D-Bus executable is reachable.
(define %test-guile (getenv "GUIX_DISK_HEALTH_TEST_GUILE"))
(check (and %test-guile (string-prefix? "/" %test-guile))
       "direct subprocess probe requires an absolute Guile path")

(define (run-child source maximum-bytes timeout-seconds)
  ((sk:make-subprocess-runner %test-guile timeout-seconds)
   (list "--no-auto-compile" "-c" source)
   maximum-bytes))

(define child-ok
  (run-child "(display \"child-ok\")" 64 2))
(check-equal (sk:command-result-kind child-ok) 'ok
             "direct child success kind")
(check-equal (sk:command-result-stdout child-ok) "child-ok"
             "direct child success output")

(define child-failure
  (run-child
   "(begin (display \"discard-me\") (display \"discard-error\" (current-error-port)) (exit 7))"
   64
   2))
(check-equal (sk:command-result-kind child-failure) 'child-exit
             "direct nonzero child kind")
(check-equal (sk:command-result-stdout child-failure) ""
             "direct nonzero child output discarded")

(define child-timeout
  (run-child "(sleep 2)" 64 1))
(check-equal (sk:command-result-kind child-timeout) 'timeout
             "direct child timeout kind")

(define child-post-eof-timeout
  (run-child "(begin (close-port (current-output-port)) (sleep 2))" 64 1))
(check-equal (sk:command-result-kind child-post-eof-timeout) 'timeout
             "direct child post-EOF timeout kind")

(define child-oversize
  (run-child "(display (make-string 128 #\\x))" 64 2))
(check-equal (sk:command-result-kind child-oversize) 'oversize
             "direct child oversize kind")
(check-equal (sk:command-result-stdout child-oversize) ""
             "direct child oversize output discarded")

(define child-invalid-utf8
  (run-child
   "(begin (use-modules (ice-9 binary-ports)) (put-u8 (current-output-port) 255))"
   64
   2))
(check-equal (sk:command-result-kind child-invalid-utf8) 'invalid-utf8
             "direct child invalid UTF-8 kind")

(define child-signal
  (run-child "(kill (getpid) SIGTERM)" 64 2))
(check-equal (sk:command-result-kind child-signal) 'signal
             "direct child signal kind")

(define child-exec-error
  ((sk:make-subprocess-runner "/p2m1a-fixture/missing-executable" 2)
   '()
   64))
(check-equal (sk:command-result-kind child-exec-error) 'runner-error
             "direct child exec error kind")

;; Help must be a zero-transport operation.
(define help-result (execute '("--help") 'allow %fixture-now))
(check-equal (result-status help-result) 0 "help exit status")
(check (contains? (result-output help-result) "usage:")
       "help output")
(check-equal (result-error help-result) "" "help stderr")
(check-equal (result-calls help-result) '() "help contacted the runner")

;; Healthy full JSON path with cached-only policy.
(define cached-result
  (execute '("--json" "--cached-only") 'cached-only %fixture-now))
(define cached-json (safe-json (result-output cached-result)))
(check-equal (result-status cached-result) 0 "cached healthy exit status")
(check-equal (result-error cached-result) "" "cached healthy stderr")
(check cached-json "cached healthy JSON parses")
(when cached-json
  (check-equal (map car cached-json)
               '("schema" "status" "classification" "activation_policy"
                 "view" "cache" "smart" "attributes")
               "cached JSON top-level key allowlist")
  (check-equal (object-ref cached-json "classification") "favorable"
               "cached healthy classification")
  (check-equal (object-ref cached-json "activation_policy") "cached-only"
               "cached activation policy")
  (check-equal (object-ref cached-json "view") "full"
               "cached full view")
  (check-equal (object-ref (object-ref cached-json "cache") "state")
               "fresh"
               "cached fresh state")
  (check-equal
   (object-ref (object-ref cached-json "smart") "self_test_status")
   "success-or-never"
   "ambiguous self-test rendering")
  (check-equal (vector-length (object-ref cached-json "attributes")) 10
               "selected attribute count"))
(check-equal (result-arguments cached-result)
             (expected-arguments 'cached-only #t)
             "cached exact argv sequence")
(check-equal (result-limits cached-result)
             (expected-limits #t)
             "cached output bounds")
(check (calls-obey-allowlist? (result-arguments cached-result) 'cached-only)
       "cached calls escaped method allowlist")
(check-equal (result-errors cached-result) '()
             "cached fake runner rejected a command")
(check-safe-result cached-result "cached healthy")

;; Default human path must make activation explicit on every call.
(define allow-result (execute '() 'allow %fixture-now))
(check-equal (result-status allow-result) 0 "allow healthy exit status")
(check (contains? (result-output allow-result) "classification: favorable")
       "allow human classification")
(check (contains? (result-output allow-result) "success-or-never")
       "allow human self-test qualification")
(check-equal (result-arguments allow-result)
             (expected-arguments 'allow #t)
             "allow exact argv sequence")
(check (calls-obey-allowlist? (result-arguments allow-result) 'allow)
       "allow calls escaped method allowlist")
(check-safe-result allow-result "allow healthy")

;; Summary mode omits detailed rendering but still reads the cached selected
;; attributes so its health classification is identical to the full view.
(define summary-result
  (execute '("--json" "--summary" "--cached-only")
           'cached-only
           %fixture-now))
(define summary-json (safe-json (result-output summary-result)))
(check-equal (result-status summary-result) 0 "summary exit status")
(when summary-json
  (check-equal (object-ref summary-json "view") "summary"
               "summary view label")
  (check (not (assoc "attributes" summary-json))
         "summary rendered attributes"))
(check-equal (result-arguments summary-result)
             (expected-arguments 'cached-only #t)
             "summary exact argv sequence")
(check-equal (result-limits summary-result)
             (expected-limits #t)
             "summary output bounds")

;; Time and failure classification use an injected clock and synthetic values.
(define stale-result
  (execute '("--json" "--cached-only")
           'cached-only
           (+ 2000000000 1201)))
(define stale-json (safe-json (result-output stale-result)))
(check-equal (result-status stale-result) 0 "stale exit status")
(when stale-json
  (check-equal (object-ref stale-json "classification") "unknown"
               "stale classification")
  (check-equal (object-ref (object-ref stale-json "cache") "state")
               "stale"
               "stale cache state"))

(define boundary-result
  (execute '("--json" "--cached-only")
           'cached-only
           (+ 2000000000 1200)))
(check-json-classification boundary-result "favorable"
                           "stale boundary remains fresh")

(define future-result
  (execute '("--json" "--cached-only")
           'cached-only
           (- 2000000000 1)))
(check-json-classification future-result "unknown" "future cache timestamp")
(let ((decoded (safe-json (result-output future-result))))
  (when decoded
    (check-equal (object-ref (object-ref decoded "cache") "state")
                 "future"
                 "future cache state")))

(define failing-result
  (execute
   '("--json" "--cached-only")
   'cached-only
   %fixture-now
   #:property-overrides
   (list (cons "SmartFailing" (variant-response "b" #t)))))
(define failing-json (safe-json (result-output failing-result)))
(check-equal (result-status failing-result) 0 "failing-indicator exit status")
(when failing-json
  (check-equal (object-ref failing-json "classification")
               "failing-indicator"
               "drive failing classification"))

(define bad-sector-result
  (execute
   '("--json" "--cached-only")
   'cached-only
   %fixture-now
   #:property-overrides
   (list (cons "SmartNumBadSectors" (variant-response "x" 1)))))
(check-json-classification bad-sector-result "failing-indicator"
                           "nonzero bad-sector indicator")

(define attribute-failing-result
  (execute
   '("--json" "--cached-only")
   'cached-only
   %fixture-now
   #:attributes-response
   (mutate-attribute %attribute-response 0 6 1)))
(check-json-classification attribute-failing-result "failing-indicator"
                           "selected nonzero attribute indicator")

(define unknown-counter-result
  (execute
   '("--json" "--cached-only")
   'cached-only
   %fixture-now
   #:property-overrides
   (list (cons "SmartNumBadSectors" (variant-response "x" -1)))))
(check-json-classification unknown-counter-result "unknown"
                           "unknown counter sentinel")

(define unknown-temperature-result
  (execute
   '("--json" "--cached-only")
   'cached-only
   %fixture-now
   #:property-overrides
   (list (cons "SmartTemperature" (variant-response "d" 0)))))
(check-json-classification unknown-temperature-result "unknown"
                           "unknown temperature sentinel")

(define unsupported-result
  (execute
   '("--json" "--cached-only")
   'cached-only
   %fixture-now
   #:property-overrides
   (list (cons "SmartSupported" (variant-response "b" #f)))))
(check-json-classification unsupported-result "unknown"
                           "SMART unsupported state")

(define in-progress-result
  (execute
   '("--json" "--cached-only")
   'cached-only
   %fixture-now
   #:property-overrides
   (list (cons "SmartSelftestStatus"
               (variant-response "s" "inprogress")))))
(check-json-classification in-progress-result "unknown"
                           "in-progress self-test state")

(define fatal-selftest-result
  (execute
   '("--json" "--cached-only")
   'cached-only
   %fixture-now
   #:property-overrides
   (list (cons "SmartSelftestStatus" (variant-response "s" "fatal")))))
(check-json-classification fatal-selftest-result "failing-indicator"
                           "fatal self-test state")

(define unknown-attribute-result
  (execute
   '("--json" "--cached-only")
   'cached-only
   %fixture-now
   #:attributes-response
   (mutate-attribute %attribute-response 0 3 -1)))
(check-json-classification unknown-attribute-result "unknown"
                           "unknown normalized attribute sentinel")

;; SmartUpdated zero invalidates all other cached SMART values and stops before
;; the optional attribute method.
(define unavailable-result
  (execute
   '("--json" "--cached-only")
   'cached-only
   %fixture-now
   #:property-overrides
   (list (cons "SmartUpdated" (variant-response "t" 0)))))
(define unavailable-json (safe-json (result-output unavailable-result)))
(check-equal (result-status unavailable-result) 69
             "SmartUpdated zero exit status")
(when unavailable-json
  (check-equal (object-ref unavailable-json "status") "unavailable"
               "SmartUpdated zero status")
  (check-equal (object-ref unavailable-json "error") "source-unavailable"
               "SmartUpdated zero error"))
(check-equal (result-arguments unavailable-result)
             (expected-arguments 'cached-only #f)
             "unavailable source called attribute method")
(check-safe-result unavailable-result "unavailable source")

;; Property framing, JSON framing, and signature failures are protocol errors.
(define wrong-type-result
  (execute '("--json" "--cached-only")
           'cached-only
           %fixture-now
           #:drive-response (variant-response "s" %drive-path)))
(check-equal (result-status wrong-type-result) 65
             "wrong Drive signature exit status")
(check-equal (result-arguments wrong-type-result)
             (list (block-command 'cached-only))
             "wrong Drive signature continued querying")
(check-safe-result wrong-type-result "wrong Drive signature")

(define malformed-result
  (execute '("--json" "--cached-only")
           'cached-only
           %fixture-now
           #:drive-response (raw-response "{\"type\":")))
(check-equal (result-status malformed-result) 65
             "malformed JSON exit status")
(check-safe-result malformed-result "malformed JSON")

(define trailing-result
  (execute
   '("--json" "--cached-only")
   'cached-only
   %fixture-now
   #:drive-response
   (raw-response
    (string-append (response-payload %drive-response)
                   "{}\n"))))
(check-equal (result-status trailing-result) 65
             "second JSON document exit status")
(check-safe-result trailing-result "second JSON document")

(define non-string-type-result
  (execute
   '("--json" "--cached-only")
   'cached-only
   %fixture-now
   #:drive-response
   `(("type" . 7) ("data" . ,(object-ref %drive-response "data")))))
(check-equal (result-status non-string-type-result) 65
             "non-string wrapper type exit status")

(define extra-key-result
  (execute '("--json" "--cached-only")
           'cached-only
           %fixture-now
           #:drive-response
           (append %drive-response '(("extra" . #t)))))
(check-equal (result-status extra-key-result) 65
             "extra property wrapper key exit status")

(define duplicate-key-result
  (execute '("--json" "--cached-only")
           'cached-only
           %fixture-now
           #:drive-response
           (append %drive-response '(("type" . "v")))))
(check-equal (result-status duplicate-key-result) 65
             "duplicate property wrapper key exit status")

(define multiple-values-result
  (execute
   '("--json" "--cached-only")
   'cached-only
   %fixture-now
   #:drive-response
   `(("type" . "v")
     ("data" . ,(vector
                  `(("type" . "o") ("data" . ,%drive-path))
                  `(("type" . "o") ("data" . ,%drive-path)))))))
(check-equal (result-status multiple-values-result) 65
             "multiple property values exit status")

(define wrong-property-scalar-result
  (execute
   '("--json" "--cached-only")
   'cached-only
   %fixture-now
   #:property-overrides
   (list (cons "SmartUpdated" (variant-response "t" "not-an-integer")))))
(check-equal (result-status wrong-property-scalar-result) 65
             "wrong property scalar type exit status")

(define non-ascii-path-result
  (execute
   '("--json" "--cached-only")
   'cached-only
   %fixture-now
   #:drive-response
   (variant-response
    "o"
    (string-append "/org/freedesktop/UDisks2/" "drives/FIXTURE_"
                   (string (integer->char #x00e9))))))
(check-equal (result-status non-ascii-path-result) 65
             "non-ASCII private object path exit status")

;; Attribute schema remains closed until future units/expansion fields receive
;; an explicit privacy and interpretation review.
(define unknown-unit-result
  (execute '("--json" "--cached-only")
           'cached-only
           %fixture-now
           #:attributes-response
           (mutate-attribute %attribute-response 0 7 4)))
(check-equal (result-status unknown-unit-result) 65
             "selected attribute wrong-unit exit status")
(check-safe-result unknown-unit-result "selected attribute wrong unit")

(define expansion-result
  (execute
   '("--json" "--cached-only")
   'cached-only
   %fixture-now
   #:attributes-response
   (mutate-attribute
    %attribute-response
    0
    8
    `(("future" . ,(variant-response "s" "synthetic"))))))
(check-equal (result-status expansion-result) 65
             "attribute expansion exit status")
(check-safe-result expansion-result "attribute expansion")

(define wrong-attribute-signature-result
  (execute
   '("--json" "--cached-only")
   'cached-only
   %fixture-now
   #:attributes-response
   `(("type" . "as")
     ("data" . ,(object-ref %attribute-response "data")))))
(check-equal (result-status wrong-attribute-signature-result) 65
             "wrong attribute signature exit status")

(define wrong-normalized-type-result
  (execute '("--json" "--cached-only")
           'cached-only
           %fixture-now
           #:attributes-response
           (mutate-attribute %attribute-response 0 3 "unknown")))
(check-equal (result-status wrong-normalized-type-result) 65
             "wrong normalized attribute type exit status")

(define negative-pretty-result
  (execute '("--json" "--cached-only")
           'cached-only
           %fixture-now
           #:attributes-response
           (mutate-attribute %attribute-response 0 6 -1)))
(check-equal (result-status negative-pretty-result) 65
             "negative selected pretty value exit status")

(define short-tuple-result
  (let* ((tuples (attribute-tuples %attribute-response))
         (short-tuple (list->vector
                       (take (vector->list (vector-ref tuples 0)) 8))))
    (execute '("--json" "--cached-only")
             'cached-only
             %fixture-now
             #:attributes-response
             (attributes-with-tuples
              (vector-set-copy tuples 0 short-tuple)))))
(check-equal (result-status short-tuple-result) 65
             "short attribute tuple exit status")

(define missing-attribute-result
  (execute '("--json" "--cached-only")
           'cached-only
           %fixture-now
           #:attributes-response
           (drop-last-attribute %attribute-response)))
(check-equal (result-status missing-attribute-result) 65
             "missing selected attribute exit status")

(define duplicate-attribute-result
  (execute '("--json" "--cached-only")
           'cached-only
           %fixture-now
           #:attributes-response
           (duplicate-first-attribute %attribute-response)))
(check-equal (result-status duplicate-attribute-result) 65
             "duplicate selected attribute exit status")

;; Neither failed child output nor exception arguments may reach a renderer.
(define %synthetic-mac
  (string-join '("aa" "bb" "cc" "dd" "ee" "ff") ":"))
(define %synthetic-uuid
  (string-append "11111111" "-2222-3333-4444-" "555555555555"))
(define %sensitive-transport-text
  (string-append "synthetic failure "
                 %drive-path
                 " "
                 "ser" "ial=SYNTHETIC_ONLY "
                 %synthetic-mac
                 " "
                 %synthetic-uuid))

(define transport-result
  (execute-with-runner
   '("--json" "--cached-only")
   (lambda (_arguments _maximum-bytes)
     (sk:make-command-result 'transport-failed
                             %sensitive-transport-text))
   %fixture-now
   #f))
(check-equal (result-status transport-result) 74
             "transport failure exit status")
(check-safe-result transport-result "transport failure")
(check (not (contains? (string-append (result-output transport-result)
                                      (result-error transport-result))
                       %synthetic-mac))
       "transport failure leaked synthetic MAC")
(check (not (contains? (string-append (result-output transport-result)
                                      (result-error transport-result))
                       %synthetic-uuid))
       "transport failure leaked synthetic UUID")

;; Runner kinds retain the source/transport/protocol distinction without
;; retaining a raw child diagnostic.  In particular, only a normal child exit
;; in cached-only mode means that the requested cached source is unavailable.
(define (check-runner-kind kind policy expected-status)
  (let* ((arguments (if (eq? policy 'cached-only)
                        '("--json" "--cached-only")
                        '("--json" "--allow-activate")))
         (label (format #f "runner kind ~a under ~a" kind policy))
         (result
          (execute-with-runner
           arguments
           (lambda (_arguments _maximum-bytes)
             (sk:make-command-result kind %sensitive-transport-text))
           %fixture-now
           #f)))
    (check-equal (result-status result) expected-status
                 (string-append label ": exit status"))
    (when (and (eq? kind 'child-exit)
               (eq? policy 'cached-only))
      (let ((rendered (safe-json (result-output result))))
        (check rendered (string-append label ": JSON parses"))
        (when rendered
          (check-equal (object-ref rendered "status") "unavailable"
                       (string-append label ": status"))
          (check-equal (object-ref rendered "error") "source-unavailable"
                       (string-append label ": error")))))
    (check-safe-result result label)))

(for-each
 (lambda (spec)
   (check-runner-kind (car spec) (cadr spec) (caddr spec)))
 '((child-exit cached-only 69)
   (child-exit allow 74)
   (timeout cached-only 74)
   (signal cached-only 74)
   (runner-error cached-only 74)
   (transport-failed cached-only 74)
   (oversize cached-only 65)
   (invalid-utf8 cached-only 65)
   (protocol-invalid cached-only 65)))

(define exception-result
  (execute-with-runner
   '("--json" "--cached-only")
   (lambda (_arguments _maximum-bytes)
     (throw 'synthetic-transport %sensitive-transport-text))
   %fixture-now
   #f))
(check-equal (result-status exception-result) 74
             "runner exception exit status")
(check-safe-result exception-result "runner exception")

;; The final renderer guard independently rejects representative identifier
;; classes.  Values are assembled at runtime so the source contains no
;; realistic hardware identifier copied from a machine.
(check (not (sk:privacy-safe? %drive-path))
       "privacy guard accepted private Drive path")
(check (not (sk:privacy-safe? %synthetic-mac))
       "privacy guard accepted MAC-shaped value")
(check (not (sk:privacy-safe? %synthetic-uuid))
       "privacy guard accepted UUID-shaped value")
(check (not (sk:privacy-safe? (string-append "ser" "ial=SYNTHETIC_ONLY")))
       "privacy guard accepted serial key")

;; Conflicting activation policies are rejected before any transport call.
(define usage-result
  (execute '("--cached-only" "--allow-activate")
           'cached-only
           %fixture-now))
(check-equal (result-status usage-result) 64
             "conflicting policy exit status")
(check-equal (result-calls usage-result) '()
             "conflicting policy contacted runner")
(check-safe-result usage-result "conflicting policy")

(if (zero? %failures)
    (begin
      (format #t "PASS: guix-disk-health offline protocol and privacy (~a checks)~%"
              %checks)
      (exit 0))
    (begin
      (format (current-error-port)
              "FAIL: guix-disk-health offline protocol and privacy (~a of ~a checks failed)~%"
              %failures
              %checks)
      (exit 1)))
