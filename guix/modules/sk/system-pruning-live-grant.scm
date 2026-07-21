;;; Pure exact D5 execution/recovery grant-token grammar for P5.2b.

(define-module (sk system-pruning-live-grant)
  #:use-module (gcrypt hash)
  #:use-module (guix base16)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:export (sk:d5-live-grant-error-key
            sk:d5-execution-grant-variable
            sk:d5-recovery-grant-variable
            sk:d5-execution-grant-schema
            sk:d5-recovery-grant-schema
            sk:d5-bootstrap-effects-schema
            sk:d5-execution-grant-context-keys
            sk:d5-recovery-grant-context-keys
            sk:assert-d5-grants-absent
            sk:assert-d5-execution-grant-context
            sk:assert-d5-recovery-grant-context
            sk:assert-d5-execution-grant
            sk:assert-d5-recovery-grant
            sk:read-d5-execution-grant-string
            sk:read-d5-recovery-grant-string
            sk:read-d5-execution-capability
            sk:read-d5-recovery-capability
            sk:render-d5-execution-grant
            sk:render-d5-recovery-grant
            sk:render-d5-bootstrap-effects
            sk:d5-bootstrap-effects-sha256))

(define sk:d5-live-grant-error-key
  'sk-system-pruning-live-grant)

(define sk:d5-execution-grant-variable
  "SK_P52B_D5_EXECUTION_GRANT")

(define sk:d5-recovery-grant-variable
  "SK_P52B_D5_RECOVERY_GRANT")

(define sk:d5-execution-grant-schema
  "p5.2b-system-prune-d5-execution-grant/v1")

(define sk:d5-recovery-grant-schema
  "p5.2b-system-prune-d5-recovery-grant/v1")

(define sk:d5-bootstrap-effects-schema
  "p5.2b-system-prune-d5-bootstrap-effects/v1")

(define %execution-record-keys
  '("schema"
    "kind"
    "source-checkpoint"
    "packet-sha256"
    "manifest-sha256"
    "program-path"
    "program-sha256"
    "program-size"
    "boot-id"
    "action"
    "selector"
    "bootstrap-effects-sha256"))

(define %recovery-record-keys
  '("schema"
    "kind"
    "source-checkpoint"
    "packet-sha256"
    "manifest-sha256"
    "program-path"
    "program-sha256"
    "program-size"
    "boot-id"
    "action"
    "attended-attestation-sha256"
    "observed-journal-head"
    "observed-state-sha256"
    "direction"
    "next-phase"))

(define %execution-context-keys
  '(source-checkpoint
    packet-sha256
    manifest-sha256
    program-path
    program-sha256
    program-size
    boot-id
    action
    selector
    bootstrap-effects-sha256))

(define %recovery-context-keys
  '(source-checkpoint
    packet-sha256
    manifest-sha256
    program-path
    program-sha256
    program-size
    boot-id
    action
    attended-attestation-sha256
    observed-journal-head
    observed-state-sha256
    direction
    next-phase))

(define (sk:d5-execution-grant-context-keys)
  "Return a fresh copy of the closed execution-context key order."
  (map (lambda (key) key) %execution-context-keys))

(define (sk:d5-recovery-grant-context-keys)
  "Return a fresh copy of the closed recovery-context key order."
  (map (lambda (key) key) %recovery-context-keys))

(define (sk:assert-d5-grants-absent execution-value recovery-value)
  "Return #t only when both optional grant environment values are #f.

The caller performs any environment lookup and passes the two results.  Every
other Scheme value, including the empty string, proves presence and fails."
  (ensure (eq? execution-value #f)
          "D5 execution grant environment value is present")
  (ensure (eq? recovery-value #f)
          "D5 recovery grant environment value is present")
  #t)

(define %guix-base32-alphabet
  "0123456789abcdfghijklmnpqrsvwxyz")

(define (%fail format-string . arguments)
  (throw sk:d5-live-grant-error-key
         (apply format #f format-string arguments)))

(define (ensure condition format-string . arguments)
  (unless condition
    (apply %fail format-string arguments)))

(define (all predicate values)
  (every predicate values))

(define (ascii-digit? character)
  (and (char>=? character #\0)
       (char<=? character #\9)))

(define (lower-hex-string? value length)
  (and (string? value)
       (= (string-length value) length)
       (all (lambda (character)
              (or (ascii-digit? character)
                  (and (char>=? character #\a)
                       (char<=? character #\f))))
            (string->list value))))

(define (lower-hex-bytes? value)
  (and (string? value)
       (not (string-null? value))
       (even? (string-length value))
       (all (lambda (character)
              (or (ascii-digit? character)
                  (and (char>=? character #\a)
                       (char<=? character #\f))))
            (string->list value))))

(define (canonical-positive-decimal? value)
  (and (string? value)
       (not (string-null? value))
       (all ascii-digit? (string->list value))
       (not (char=? (string-ref value 0) #\0))))

(define (strictly-increasing-positive-decimal-csv? value)
  (and (string? value)
       (not (string-null? value))
       (let ((fields (string-split value #\,)))
         (and (all canonical-positive-decimal? fields)
              (let loop ((remaining fields)
                         (previous #f))
                (if (null? remaining)
                    #t
                    (let ((current (string->number (car remaining) 10)))
                      (and (or (not previous) (< previous current))
                           (loop (cdr remaining) current)))))))))

(define (safe-atom-character? character)
  (or (and (char>=? character #\a) (char<=? character #\z))
      (and (char>=? character #\A) (char<=? character #\Z))
      (ascii-digit? character)
      (memv character '(#\- #\_ #\. #\: #\+ #\@ #\= #\,))))

(define (safe-atom? value)
  (and (string? value)
       (not (string-null? value))
       (all safe-atom-character? (string->list value))))

(define (boot-id? value)
  (and (string? value)
       (= (string-length value) 36)
       (char=? (string-ref value 8) #\-)
       (char=? (string-ref value 13) #\-)
       (char=? (string-ref value 18) #\-)
       (char=? (string-ref value 23) #\-)
       (lower-hex-string?
        (string-append (substring value 0 8)
                       (substring value 9 13)
                       (substring value 14 18)
                       (substring value 19 23)
                       (substring value 24 36))
        32)))

(define (program-store-path? path)
  (and (string? path)
       (string-prefix? "/gnu/store/" path)
       (not (string-contains path "//"))
       (not (string-suffix? "/" path))
       (let* ((name (substring path (string-length "/gnu/store/")))
              (dash (string-index name #\-)))
         (and dash
              (= dash 32)
              (not (string-contains name "/"))
              (all (lambda (character)
                     (string-index %guix-base32-alphabet character))
                   (string->list (substring name 0 dash)))
              (string=? (substring name dash)
                        "-system-pruning-loaded.scm")))))

(define %bootstrap-recovery-phases
  '("transaction-base"
    "transaction-lock"
    "system-lock"
    "recovery-root-base"
    "root-namespace"
    "transaction-directory"
    "quarantine"
    "initial-journal"))

(define (durable-root-recovery-phase? value)
  (and (string? value)
       (string-prefix? "durable-root:" value)
       (let ((name (substring value (string-length "durable-root:"))))
         (or (member name '("old-bootcfg" "new-bootcfg"))
             (and (string-prefix? "candidate-g" name)
                  (canonical-positive-decimal?
                   (substring name (string-length "candidate-g"))))))))

(define (bootstrap-recovery-phase? value)
  (or (and (string? value) (member value %bootstrap-recovery-phases))
      (durable-root-recovery-phase? value)))

(define (record-value records key)
  (let ((record (find (lambda (candidate)
                        (and (pair? candidate)
                             (string? (car candidate))
                             (string=? (car candidate) key)))
                      records)))
    (ensure record "missing grant record: ~a" key)
    (cadr record)))

(define (context-value context key)
  (let ((entry (assq key context)))
    (ensure entry "missing expected grant binding: ~s" key)
    (cdr entry)))

(define (assert-closed-context context keys label)
  (ensure (and (list? context)
               (all (lambda (entry)
                      (and (pair? entry)
                           (symbol? (car entry))
                           (string? (cdr entry))))
                    context)
               (equal? (map car context) keys))
          "~a keys, order, shape, or value type differ from the closed model"
          label)
  context)

(define (assert-common-context context)
  (ensure (lower-hex-string? (context-value context 'source-checkpoint) 40)
          "source checkpoint is not a lowercase 40-hex identity")
  (ensure (lower-hex-string? (context-value context 'packet-sha256) 64)
          "execution-packet SHA256 is invalid")
  (ensure (lower-hex-string? (context-value context 'manifest-sha256) 64)
          "live-manifest SHA256 is invalid")
  (ensure (program-store-path? (context-value context 'program-path))
          "fused-program path is not the exact store-item form")
  (ensure (lower-hex-string? (context-value context 'program-sha256) 64)
          "fused-program SHA256 is invalid")
  (ensure (canonical-positive-decimal?
           (context-value context 'program-size))
          "fused-program size is not a canonical positive decimal")
  (ensure (boot-id? (context-value context 'boot-id))
          "boot ID is not a canonical lowercase UUID")
  context)

(define (sk:assert-d5-execution-grant-context context)
  "Validate and return one closed expected initial-execution CONTEXT."
  (assert-closed-context
   context %execution-context-keys "execution-grant context")
  (assert-common-context context)
  (ensure (string=? (context-value context 'action) "live-apply")
          "execution grant action is not live-apply")
  (ensure (strictly-increasing-positive-decimal-csv?
           (context-value context 'selector))
          "execution grant selector is not increasing positive-decimal CSV")
  (ensure (lower-hex-string?
           (context-value context 'bootstrap-effects-sha256) 64)
          "ordered bootstrap-effect digest is invalid")
  context)

(define (sk:assert-d5-recovery-grant-context context)
  "Validate and return one closed expected recovery-continuation CONTEXT."
  (assert-closed-context
   context %recovery-context-keys "recovery-grant context")
  (assert-common-context context)
  (ensure (string=? (context-value context 'action) "live-recover")
          "recovery grant action is not live-recover")
  (ensure (lower-hex-string?
           (context-value context 'attended-attestation-sha256) 64)
          "attended recovery-attestation SHA256 is invalid")
  (ensure (string=? (context-value context 'observed-journal-head) "ABSENT")
          "durable-journal recovery is not enabled by this source checkpoint")
  (ensure (lower-hex-string?
           (context-value context 'observed-state-sha256) 64)
          "observed bootstrap-state SHA256 is invalid")
  (ensure (string=? (context-value context 'direction) "BOOTSTRAP")
          "pre-journal recovery direction is not BOOTSTRAP")
  (ensure (bootstrap-recovery-phase?
           (context-value context 'next-phase))
          "recovery next phase is not an accepted bootstrap phase")
  context)

(define (context->records schema kind context)
  (append
   (list (list "schema" schema)
         (list "kind" kind))
   (map (lambda (entry)
          (list (symbol->string (car entry)) (cdr entry)))
        context)))

(define (assert-record-shape records keys label)
  (ensure (and (list? records)
               (all (lambda (record)
                      (and (list? record)
                           (= (length record) 2)
                           (string? (car record))
                           (string? (cadr record))
                           (not (string-null? (car record)))
                           (not (string-null? (cadr record)))))
                    records)
               (equal? (map car records) keys))
          "~a fields, order, duplication, or shape differ from the closed grammar"
          label)
  records)

(define (records->context records keys)
  (map (lambda (key)
         (cons key (record-value records (symbol->string key))))
       keys))

(define (assert-exact-bindings records expected keys)
  (for-each
   (lambda (key)
     (let ((observed (record-value records (symbol->string key)))
           (wanted (context-value expected key)))
       (ensure (string=? observed wanted)
               "grant binding mismatch for ~s" key)))
   keys)
  records)

(define (assert-execution-records records)
  (assert-record-shape records %execution-record-keys "execution grant")
  (ensure (string=? (record-value records "schema")
                    sk:d5-execution-grant-schema)
          "execution grant schema is invalid")
  (ensure (string=? (record-value records "kind") "EXECUTION")
          "execution grant kind is invalid")
  (sk:assert-d5-execution-grant-context
   (records->context records %execution-context-keys))
  records)

(define (assert-recovery-records records)
  (assert-record-shape records %recovery-record-keys "recovery grant")
  (ensure (string=? (record-value records "schema")
                    sk:d5-recovery-grant-schema)
          "recovery grant schema is invalid")
  (ensure (string=? (record-value records "kind") "RECOVERY")
          "recovery grant kind is invalid")
  (sk:assert-d5-recovery-grant-context
   (records->context records %recovery-context-keys))
  records)

(define (sk:assert-d5-execution-grant records expected-context)
  "Validate RECORDS as an execution grant bound exactly to EXPECTED-CONTEXT."
  (assert-execution-records records)
  (sk:assert-d5-execution-grant-context expected-context)
  (assert-exact-bindings
   records expected-context %execution-context-keys))

(define (sk:assert-d5-recovery-grant records expected-context)
  "Validate RECORDS as a recovery grant bound exactly to EXPECTED-CONTEXT."
  (assert-recovery-records records)
  (sk:assert-d5-recovery-grant-context expected-context)
  (assert-exact-bindings
   records expected-context %recovery-context-keys))

(define (render-records records)
  (string-concatenate
   (map (lambda (record)
          (string-append (car record) "\t" (cadr record) "\n"))
        records)))

(define (parse-canonical-tsv text)
  (ensure (string? text) "grant token is not a string")
  (ensure (not (string-null? text)) "grant token is empty")
  (ensure (not (string-index text #\return))
          "grant token contains a carriage return")
  (ensure (not (string-index text #\nul))
          "grant token contains NUL")
  (ensure (string-suffix? "\n" text)
          "grant token lacks its canonical final LF")
  (let* ((body (substring text 0 (- (string-length text) 1)))
         (lines (string-split body #\newline)))
    (ensure (and (not (string-null? body))
                 (all (lambda (line) (not (string-null? line))) lines))
            "grant token contains an empty row")
    (let ((records
           (map (lambda (line)
                  (let ((fields (string-split line #\tab)))
                    (ensure (= (length fields) 2)
                            "grant row is not exact two-column TSV: ~s" line)
                    (ensure (and (not (string-null? (car fields)))
                                 (not (string-null? (cadr fields))))
                            "grant row contains an empty field")
                    fields))
                lines)))
      (ensure (string=? text (render-records records))
              "grant bytes are not canonical LF TSV")
      records)))

(define (encode-grant-transport text)
  ;; Grant tokens cross Fish and process-environment boundaries as one
  ;; newline-free value.  The transported value is exactly lowercase base16
  ;; of the canonical UTF-8 TSV bytes, not a second permissive text grammar.
  (bytevector->base16-string (string->utf8 text)))

(define (decode-grant-transport value)
  (ensure (lower-hex-bytes? value)
          "grant transport is not nonempty canonical lowercase byte hex")
  (let ((bytes (base16-string->bytevector value)))
    (catch #t
      (lambda ()
        (let ((text (utf8->string bytes)))
          (ensure (bytevector=? bytes (string->utf8 text))
                  "grant transport is not canonical UTF-8")
          text))
      (lambda _arguments
        (%fail "grant transport does not decode as canonical UTF-8 text")))))

(define (sk:read-d5-grant-string text)
  "Decode lowercase-hex TEXT and return one intrinsically valid D5 grant."
  (let ((records (parse-canonical-tsv (decode-grant-transport text))))
    (cond
     ((and (pair? records)
           (equal? (car records)
                   (list "schema" sk:d5-execution-grant-schema)))
      (assert-execution-records records))
     ((and (pair? records)
           (equal? (car records)
                   (list "schema" sk:d5-recovery-grant-schema)))
      (assert-recovery-records records))
     (else
      (%fail "unknown or misplaced D5 grant schema")))))

(define (sk:read-d5-execution-grant-string text expected-context)
  "Decode TEXT only as an execution grant bound to EXPECTED-CONTEXT."
  (sk:assert-d5-execution-grant
   (sk:read-d5-grant-string text) expected-context))

(define (sk:read-d5-recovery-grant-string text expected-context)
  "Decode TEXT only as a recovery grant bound to EXPECTED-CONTEXT."
  (sk:assert-d5-recovery-grant
   (sk:read-d5-grant-string text) expected-context))

(define (sk:read-d5-execution-capability execution-value recovery-value
                                         expected-context)
  "Require only the execution variable and bind it to EXPECTED-CONTEXT."
  (ensure (eq? recovery-value #f)
          "D5 recovery grant is present during initial execution")
  (ensure (string? execution-value)
          "D5 execution grant is absent or not text")
  (sk:read-d5-execution-grant-string execution-value expected-context))

(define (sk:read-d5-recovery-capability execution-value recovery-value
                                        expected-context)
  "Require only the recovery variable and bind it to EXPECTED-CONTEXT."
  (ensure (eq? execution-value #f)
          "D5 execution grant is present during recovery")
  (ensure (string? recovery-value)
          "D5 recovery grant is absent or not text")
  (sk:read-d5-recovery-grant-string recovery-value expected-context))

(define (sk:render-d5-execution-grant context)
  "Render one lowercase-hex environment value for closed CONTEXT."
  (sk:assert-d5-execution-grant-context context)
  (encode-grant-transport
   (render-records
    (context->records
     sk:d5-execution-grant-schema "EXECUTION" context))))

(define (sk:render-d5-recovery-grant context)
  "Render one lowercase-hex recovery environment value for closed CONTEXT."
  (sk:assert-d5-recovery-grant-context context)
  (encode-grant-transport
   (render-records
    (context->records
     sk:d5-recovery-grant-schema "RECOVERY" context))))

(define (assert-bootstrap-effects effects)
  (ensure (and (list? effects) (pair? effects) (all safe-atom? effects))
          "ordered bootstrap effects are empty or malformed")
  (ensure (= (length effects) (length (delete-duplicates effects)))
          "ordered bootstrap effects contain a duplicate label")
  effects)

(define (sk:render-d5-bootstrap-effects effects)
  "Render the canonical ordered bootstrap-effect digest input."
  (assert-bootstrap-effects effects)
  (string-append
   "schema\t" sk:d5-bootstrap-effects-schema "\n"
   (string-concatenate
    (map (lambda (index effect)
           (string-append "effect\t"
                          (number->string index)
                          "\t"
                          effect
                          "\n"))
         (iota (length effects) 1)
         effects))))

(define (sk:d5-bootstrap-effects-sha256 effects)
  "Return SHA256 of the canonical, ordinal-bearing ordered EFFECTS bytes."
  (bytevector->base16-string
   (bytevector-hash
    (string->utf8 (sk:render-d5-bootstrap-effects effects))
    (hash-algorithm sha256))))
