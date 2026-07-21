;;; Pure positive/adversarial checks for the exact P5.2b-D5 grant grammar.

(use-modules (guix base16)
             (rnrs bytevectors)
             (sk system-pruning-live-grant)
             (srfi srfi-1))

(define %program "guix-system-pruning-live-grant-check")
(define %checks 0)

(define (check condition label)
  (set! %checks (+ %checks 1))
  (unless condition
    (error %program label)))

(define (expect-failure thunk label)
  (set! %checks (+ %checks 1))
  (let ((failed?
         (catch sk:d5-live-grant-error-key
           (lambda ()
             (thunk)
             #f)
           (lambda _arguments #t))))
    (unless failed?
      (error %program (string-append "expected failure: " label)))))

(define (context-set context key value)
  (map (lambda (entry)
         (if (eq? (car entry) key)
             (cons key value)
             entry))
       context))

(define (context-remove context key)
  (filter (lambda (entry) (not (eq? (car entry) key))) context))

(define (row-set records key value)
  (map (lambda (record)
         (if (string=? (car record) key)
             (list key value)
             record))
       records))

(define (row-remove records key)
  (filter (lambda (record) (not (string=? (car record) key))) records))

(define (rows->text records)
  (string-concatenate
   (map (lambda (record)
          (string-append (car record) "\t" (cadr record) "\n"))
        records)))

(define (text->transport text)
  (bytevector->base16-string (string->utf8 text)))

(define (transport->text transport)
  (utf8->string (base16-string->bytevector transport)))

(define (rows->transport records)
  (text->transport (rows->text records)))

(define (replace-once text old replacement)
  (let ((index (string-contains text old)))
    (unless index (error %program "test replacement source is absent" old))
    (string-append (substring text 0 index)
                   replacement
                   (substring text (+ index (string-length old))))))

(define %source-checkpoint (make-string 40 #\a))
(define %packet-sha (make-string 64 #\b))
(define %manifest-sha (make-string 64 #\c))
(define %program-path
  "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system-pruning-loaded.scm")
(define %program-sha (make-string 64 #\d))
(define %boot-id "12345678-1234-4abc-8def-1234567890ab")

(define %bootstrap-effects
  '("program-temporary-root"
    "program-root"
    "transaction-base"
    "transaction-lock"
    "system-lock"
    "remaining-temporary-roots"
    "durable-recovery-roots"
    "transaction-directory"
    "quarantine"
    "initial-journal"
    "old-grub-backup"))

(define %bootstrap-text
  (string-append
   "schema\tp5.2b-system-prune-d5-bootstrap-effects/v1\n"
   "effect\t1\tprogram-temporary-root\n"
   "effect\t2\tprogram-root\n"
   "effect\t3\ttransaction-base\n"
   "effect\t4\ttransaction-lock\n"
   "effect\t5\tsystem-lock\n"
   "effect\t6\tremaining-temporary-roots\n"
   "effect\t7\tdurable-recovery-roots\n"
   "effect\t8\ttransaction-directory\n"
   "effect\t9\tquarantine\n"
   "effect\t10\tinitial-journal\n"
   "effect\t11\told-grub-backup\n"))

(define %bootstrap-sha
  (sk:d5-bootstrap-effects-sha256 %bootstrap-effects))

(define %execution-context
  `((source-checkpoint . ,%source-checkpoint)
    (packet-sha256 . ,%packet-sha)
    (manifest-sha256 . ,%manifest-sha)
    (program-path . ,%program-path)
    (program-sha256 . ,%program-sha)
    (program-size . "48231")
    (boot-id . ,%boot-id)
    (action . "live-apply")
    (selector . "1,2,7,19")
    (bootstrap-effects-sha256 . ,%bootstrap-sha)))

(define %expected-execution-text
  (string-append
   "schema\tp5.2b-system-prune-d5-execution-grant/v1\n"
   "kind\tEXECUTION\n"
   "source-checkpoint\t" %source-checkpoint "\n"
   "packet-sha256\t" %packet-sha "\n"
   "manifest-sha256\t" %manifest-sha "\n"
   "program-path\t" %program-path "\n"
   "program-sha256\t" %program-sha "\n"
   "program-size\t48231\n"
   "boot-id\t" %boot-id "\n"
   "action\tlive-apply\n"
   "selector\t1,2,7,19\n"
   "bootstrap-effects-sha256\t" %bootstrap-sha "\n"))

(define %observed-state-sha (make-string 64 #\f))

(define %recovery-context
  `((source-checkpoint . ,%source-checkpoint)
    (packet-sha256 . ,%packet-sha)
    (manifest-sha256 . ,%manifest-sha)
    (program-path . ,%program-path)
    (program-sha256 . ,%program-sha)
    (program-size . "48231")
    (boot-id . ,%boot-id)
    (action . "live-recover")
    (attended-attestation-sha256 . ,(make-string 64 #\1))
    (observed-journal-head . "ABSENT")
    (observed-state-sha256 . ,%observed-state-sha)
    (direction . "BOOTSTRAP")
    (next-phase . "transaction-base")))

(define %expected-recovery-text
  (string-append
   "schema\tp5.2b-system-prune-d5-recovery-grant/v1\n"
   "kind\tRECOVERY\n"
   "source-checkpoint\t" %source-checkpoint "\n"
   "packet-sha256\t" %packet-sha "\n"
   "manifest-sha256\t" %manifest-sha "\n"
   "program-path\t" %program-path "\n"
   "program-sha256\t" %program-sha "\n"
   "program-size\t48231\n"
   "boot-id\t" %boot-id "\n"
   "action\tlive-recover\n"
   "attended-attestation-sha256\t" (make-string 64 #\1) "\n"
   "observed-journal-head\tABSENT\n"
   "observed-state-sha256\t" %observed-state-sha "\n"
   "direction\tBOOTSTRAP\n"
   "next-phase\ttransaction-base\n"))

(define %execution-token
  (sk:render-d5-execution-grant %execution-context))
(define %recovery-token
  (sk:render-d5-recovery-grant %recovery-context))
(define %execution-records
  (sk:read-d5-execution-grant-string
   %execution-token %execution-context))
(define %recovery-records
  (sk:read-d5-recovery-grant-string
   %recovery-token %recovery-context))

;; Canonical ordered-effect digest input and newline-free environment transport.
(check (string=? sk:d5-execution-grant-variable
                 "SK_P52B_D5_EXECUTION_GRANT")
       "execution grant environment-variable name drifted")
(check (string=? sk:d5-recovery-grant-variable
                 "SK_P52B_D5_RECOVERY_GRANT")
       "recovery grant environment-variable name drifted")
(check (equal? (sk:d5-execution-grant-context-keys)
               '(source-checkpoint packet-sha256 manifest-sha256 program-path
                 program-sha256 program-size boot-id action selector
                 bootstrap-effects-sha256))
       "execution context key order drifted")
(check (equal? (sk:d5-recovery-grant-context-keys)
               '(source-checkpoint packet-sha256 manifest-sha256 program-path
                 program-sha256 program-size boot-id action
                 attended-attestation-sha256 observed-journal-head
                 observed-state-sha256 direction next-phase))
       "recovery context key order drifted")
(let ((public-copy (sk:d5-execution-grant-context-keys)))
  (set-car! public-copy 'poison)
  (check (and (eq? (car public-copy) 'poison)
              (eq? (car (sk:d5-execution-grant-context-keys))
                   'source-checkpoint))
         "public key-order mutation poisoned private grammar state"))
(check (sk:assert-d5-grants-absent #f #f)
       "two absent grant environment values were not accepted")
(check (string=? (sk:render-d5-bootstrap-effects %bootstrap-effects)
                 %bootstrap-text)
       "ordered bootstrap-effect bytes drifted")
(check (= (string-length %bootstrap-sha) 64)
       "bootstrap-effect digest length is not SHA256")
(check (string=? %bootstrap-sha
                 (sk:d5-bootstrap-effects-sha256 %bootstrap-effects))
       "bootstrap-effect digest is not deterministic")
(check (not (string=? %bootstrap-sha
                      (sk:d5-bootstrap-effects-sha256
                       (append (list (cadr %bootstrap-effects)
                                     (car %bootstrap-effects))
                               (drop %bootstrap-effects 2)))))
       "bootstrap-effect digest ignored order")
(check (and (not (string-index %execution-token #\newline))
            (not (string-index %execution-token #\tab))
            (every (lambda (character)
                     (or (and (char>=? character #\0)
                              (char<=? character #\9))
                         (and (char>=? character #\a)
                              (char<=? character #\f))))
                   (string->list %execution-token)))
       "execution environment value is not lowercase hex")

;; Exact positive execution and recovery round trips.
(check (equal? (sk:assert-d5-execution-grant-context %execution-context)
               %execution-context)
       "execution context was not accepted")
(check (equal? (sk:assert-d5-recovery-grant-context %recovery-context)
               %recovery-context)
       "recovery context was not accepted")
(check (equal? (sk:read-d5-execution-grant-string
                %execution-token %execution-context)
               %execution-records)
       "execution token did not round-trip")
(check (equal? (sk:read-d5-recovery-grant-string
                %recovery-token %recovery-context)
               %recovery-records)
       "recovery token did not round-trip")
(check (equal? (sk:read-d5-execution-capability
                %execution-token #f %execution-context)
               %execution-records)
       "execution-only environment capability was rejected")
(check (equal? (sk:read-d5-recovery-capability
                #f %recovery-token %recovery-context)
               %recovery-records)
       "recovery-only environment capability was rejected")
(for-each
 (lambda (phase)
   (let* ((context (context-set %recovery-context 'next-phase phase))
          (token (sk:render-d5-recovery-grant context)))
     (check (pair? (sk:read-d5-recovery-capability #f token context))
            (string-append "canonical durable-root phase was rejected: "
                           phase))))
 '("durable-root:candidate-g1"
   "durable-root:old-bootcfg"
   "durable-root:new-bootcfg"))
(for-each
 (lambda (thunk label) (expect-failure thunk label))
 (list
  (lambda ()
    (sk:read-d5-execution-capability
     %execution-token %recovery-token %execution-context))
  (lambda ()
    (sk:read-d5-execution-capability #f #f %execution-context))
  (lambda ()
    (sk:read-d5-recovery-capability
     %execution-token %recovery-token %recovery-context))
  (lambda ()
    (sk:read-d5-recovery-capability #f #f %recovery-context)))
 '("recovery grant accompanied execution capability"
   "execution capability was absent"
   "execution grant accompanied recovery capability"
   "recovery capability was absent"))
(check (string=? (transport->text %execution-token)
                 %expected-execution-text)
       "execution transport did not decode to the exact canonical TSV")
(check (string=? (transport->text %recovery-token)
                 %expected-recovery-text)
       "recovery transport did not decode to the exact canonical TSV")
(check (string=? %execution-token
                 (text->transport %expected-execution-text))
       "execution transport does not have one exact canonical encoding")
(check (string=? %recovery-token
                 (text->transport %expected-recovery-text))
       "recovery transport does not have one exact canonical encoding")

;; Presence is a capability fact, not a truthy/nonempty convention.  Empty
;; values and even non-string caller values remain present and fail closed.
(for-each
 (lambda (execution recovery label)
   (expect-failure
    (lambda () (sk:assert-d5-grants-absent execution recovery))
    label))
 (list "value" #f "value" "" #f #t)
 (list #f "value" "value" #f "" #f)
 '("execution grant present"
   "recovery grant present"
   "both grants present"
   "empty execution grant present"
   "empty recovery grant present"
   "non-string execution grant present"))

;; The environment transport itself is closed: no raw TSV, case variants,
;; odd/non-hex bytes, empty value, or invalid UTF-8 are alternatives.
(for-each
 (lambda (value label)
   (expect-failure
    (lambda ()
      (sk:read-d5-execution-grant-string value %execution-context))
    label))
 (list (transport->text %execution-token)
       (string-upcase %execution-token)
       (string-append %execution-token "0")
       (string-append (substring %execution-token
                                 0 (- (string-length %execution-token) 2))
                      "gg")
       ""
       "ff")
 '("raw TSV environment value"
   "uppercase hex environment value"
   "odd-length hex environment value"
   "non-hex environment value"
   "empty environment value"
   "invalid UTF-8 environment value"))

;; Decoded bytes must remain exact final-LF, two-column TSV without CR/NUL or
;; empty rows.  Every malformed payload is nevertheless valid lowercase hex,
;; proving rejection happens after transport decoding as intended.
(let ((text (transport->text %execution-token)))
  (for-each
   (lambda (payload label)
     (expect-failure
      (lambda ()
        (sk:read-d5-execution-grant-string
         (text->transport payload) %execution-context))
      label))
   (list (substring text 0 (- (string-length text) 1))
         (string-append text "\n")
         (string-append "\n" text)
         (replace-once text "\n" "\r\n")
         (string-append (substring text 0 (- (string-length text) 1))
                        (string #\nul)
                        "\n")
         (replace-once text "action\tlive-apply\n"
                       "action\tlive-apply\textra\n")
         (replace-once text "action\tlive-apply\n"
                       "action live-apply\n")
         (replace-once text "action\tlive-apply\n"
                       "action\t\n"))
   '("missing final LF"
     "extra final LF"
     "leading empty row"
     "CRLF payload"
     "NUL payload"
     "extra TSV column"
     "missing TSV separator"
     "empty TSV value")))

;; Closed row set/order rejects unknown, missing, reordered, duplicate, wrong
;; schema/kind/action, and cross-kind use.
(for-each
 (lambda (records label)
   (expect-failure
    (lambda ()
      (sk:read-d5-execution-grant-string
       (rows->transport records) %execution-context))
    label))
 (list (append %execution-records '( ("unknown" "value")))
       (row-remove %execution-records "selector")
       (append (take %execution-records 2)
               (list (list-ref %execution-records 3)
                     (list-ref %execution-records 2))
               (drop %execution-records 4))
       (append (take %execution-records 10)
               (list (list "action" "live-apply"))
               (drop %execution-records 10))
       (row-set %execution-records "schema" sk:d5-recovery-grant-schema)
       (row-set %execution-records "kind" "RECOVERY")
       (row-set %execution-records "action" "live-recover"))
 '("unknown execution field"
   "missing execution field"
   "reordered execution fields"
   "duplicate execution field"
   "execution rows under recovery schema"
   "wrong execution kind"
   "wrong execution action"))

(for-each
 (lambda (records label)
   (expect-failure
    (lambda ()
      (sk:read-d5-recovery-grant-string
       (rows->transport records) %recovery-context))
    label))
 (list (append %recovery-records '( ("selector" "1,2,7,19")))
       (row-remove %recovery-records "direction")
       (row-set %recovery-records "schema" sk:d5-execution-grant-schema)
       (row-set %recovery-records "kind" "EXECUTION")
       (row-set %recovery-records "action" "live-apply"))
 '("unknown recovery field"
   "missing recovery field"
   "recovery rows under execution schema"
   "wrong recovery kind"
   "wrong recovery action"))

(expect-failure
 (lambda ()
   (sk:read-d5-execution-grant-string
    %recovery-token %execution-context))
 "recovery token accepted through execution API")
(expect-failure
 (lambda ()
   (sk:read-d5-recovery-grant-string
    %execution-token %recovery-context))
 "execution token accepted through recovery API")
;; Every execution binding is compared with independently supplied expected
;; context.  All alternates below remain intrinsically valid, so these checks
;; specifically exercise mismatch rejection rather than field parsing.
(for-each
 (lambda (spec)
   (let ((key (car spec)) (alternate (cadr spec)))
     (expect-failure
      (lambda ()
        (sk:read-d5-execution-grant-string
         %execution-token
         (context-set %execution-context key alternate)))
      (string-append "execution expected-context mismatch: "
                     (symbol->string key)))))
 `((source-checkpoint ,(make-string 40 #\b))
   (packet-sha256 ,(make-string 64 #\c))
   (manifest-sha256 ,(make-string 64 #\d))
   (program-path
    "/gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-system-pruning-loaded.scm")
   (program-sha256 ,(make-string 64 #\a))
   (program-size "48232")
   (boot-id "22345678-1234-4abc-8def-1234567890ab")
   (selector "1,2,7,20")
   (bootstrap-effects-sha256 ,(make-string 64 #\a))))

;; The same exact binding rule applies to every recovery-specific identity.
(for-each
 (lambda (spec)
   (let ((key (car spec)) (alternate (cadr spec)))
     (expect-failure
      (lambda ()
        (sk:read-d5-recovery-grant-string
         %recovery-token
         (context-set %recovery-context key alternate)))
      (string-append "recovery expected-context mismatch: "
                     (symbol->string key)))))
 `((source-checkpoint ,(make-string 40 #\b))
   (packet-sha256 ,(make-string 64 #\c))
   (manifest-sha256 ,(make-string 64 #\d))
   (program-path
    "/gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-system-pruning-loaded.scm")
   (program-sha256 ,(make-string 64 #\a))
   (program-size "48232")
   (boot-id "22345678-1234-4abc-8def-1234567890ab")
   (attended-attestation-sha256 ,(make-string 64 #\2))
   (observed-state-sha256 ,(make-string 64 #\a))
   (next-phase "transaction-lock")))

;; Intrinsic identity, path, number, selector, journal, and phase grammars are
;; canonical rather than merely nonempty.
(for-each
 (lambda (spec)
   (expect-failure
    (lambda ()
      (sk:render-d5-execution-grant
       (context-set %execution-context (car spec) (cadr spec))))
    (string-append "malformed execution context: "
                   (symbol->string (car spec)))))
 `((source-checkpoint ,(make-string 39 #\a))
   (source-checkpoint ,(string-upcase %source-checkpoint))
   (packet-sha256 ,(make-string 64 #\g))
   (manifest-sha256 ,(make-string 63 #\c))
   (program-path
    "/gnu/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-system-pruning-loaded.scm")
   (program-path
    "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-extra-system-pruning-loaded.scm")
   (program-path
    "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system-pruning-loaded.scm/child")
   (program-sha256 ,(string-upcase %program-sha))
   (program-size "0")
   (program-size "01")
   (program-size "+1")
   (boot-id "12345678-1234-4ABC-8def-1234567890ab")
   (boot-id "1234567812344abc8def1234567890ab")
   (action "live-recover")
   (selector "01,2,7,19")
   (selector "1,7,2,19")
   (selector "1,2,2,19")
   (selector "1,,7,19")
   (bootstrap-effects-sha256 ,(make-string 64 #\A))))

(for-each
 (lambda (spec)
   (expect-failure
    (lambda ()
      (sk:render-d5-recovery-grant
       (context-set %recovery-context (car spec) (cadr spec))))
    (string-append "malformed recovery context: "
                   (symbol->string (car spec)))))
 `((action "live-apply")
   (attended-attestation-sha256 ,(make-string 63 #\1))
   (observed-journal-head "0:BEGIN:-:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
   (observed-journal-head "ABSENT ")
   (observed-state-sha256 ,(make-string 64 #\A))
   (observed-state-sha256 ,(make-string 63 #\a))
   (direction "FORWARD")
   (direction "ROLLBACK")
   (direction "RESUME")
   (next-phase "")
   (next-phase "phase with space")
   (next-phase "../phase")
   (next-phase "journal-COMMITTED")
   (next-phase "reconcile-initial-journal")
   (next-phase "durable-root:")
   (next-phase "durable-root:not-a-root")
   (next-phase "durable-root:candidate-g0")
   (next-phase "durable-root:candidate-g01")
   (next-phase "durable-root:bad:name")))

(expect-failure
 (lambda ()
   (sk:render-d5-recovery-grant
    (context-set %recovery-context 'observed-journal-head
                 "1:BEGIN:-:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")))
 "present journal head was accepted before its recovery contract")

;; Expected contexts themselves are closed and ordered.
(for-each
 (lambda (context label)
   (expect-failure
    (lambda () (sk:assert-d5-execution-grant-context context))
    label))
 (list (context-remove %execution-context 'selector)
       (append %execution-context '((unknown . "value")))
       (append (take %execution-context 1)
               (list (list-ref %execution-context 2)
                     (list-ref %execution-context 1))
               (drop %execution-context 3))
       (append %execution-context
               (list (cons 'selector "1,2,7,19"))))
 '("missing execution context key"
   "unknown execution context key"
   "reordered execution context keys"
   "duplicate execution context key"))

(expect-failure
 (lambda ()
   (sk:assert-d5-recovery-grant-context
    (append %recovery-context '((unknown . "value")))))
 "unknown recovery context key")

;; Ordered effect inputs reject omission of the entire plan, ambiguity through
;; duplicate labels, and noncanonical labels containing separators/newlines.
(for-each
 (lambda (effects label)
   (expect-failure
    (lambda () (sk:d5-bootstrap-effects-sha256 effects))
    label))
 (list '()
       (append %bootstrap-effects (list (car %bootstrap-effects)))
       '("program-root" "bad\teffect")
       '("program-root" "bad effect")
       '("program-root" "bad/effect"))
 '("empty bootstrap-effect set"
   "duplicate bootstrap effect"
   "tab in bootstrap effect"
   "space in bootstrap effect"
   "slash in bootstrap effect"))

(format #t "~a: PASS (~a checks)~%" %program %checks)
