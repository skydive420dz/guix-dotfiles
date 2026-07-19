;;; Pure P5.2b-D4a production-boundary safety model.

(define-module (sk system-pruning-boundary)
  #:use-module (gcrypt hash)
  #:use-module (guix base16)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:export (sk:boundary-error-key
            sk:assert-boundary-manifest
            sk:boundary-roots
            sk:legal-journal-traces
            sk:call-with-journal-trace-cache
            sk:legal-journal-prefix?
            sk:journal-legal-successors
            sk:journal-head
            sk:journal-history-status
            sk:assert-legal-journal-history
            sk:assert-legal-journal-successor
            sk:render-journal
            sk:parse-journal
            sk:append-journal-event
            sk:exact-byte-prefix?
            sk:assert-construction-prefix
            sk:classify-bootstrap
            sk:classify-legacy-gap
            sk:call-with-pre-phase-gate
            sk:terminal-cleanup-plan
            sk:assert-terminal-cleanup-prefix))

(define sk:boundary-error-key 'sk-system-pruning-boundary)

(define %manifest-schema "p5.2b-system-prune-boundary/v1")
(define %journal-schema "p5.2b-system-prune-journal/v1")
(define %manifest-keys
  '(schema mode authorization manifest-sha program-root roots phases))
(define %guard-keys '(protected journal roots session quiescence))
(define %guix-base32-alphabet
  "0123456789abcdfghijklmnpqrsvwxyz")

(define (%fail format-string . arguments)
  (throw sk:boundary-error-key
         (apply format #f format-string arguments)))

(define (ensure condition format-string . arguments)
  (unless condition
    (apply %fail format-string arguments)))

(define (all predicate values)
  (every predicate values))

(define (string-sha256 value)
  (bytevector->base16-string
   (bytevector-hash
    (string->utf8 value)
    (hash-algorithm sha256))))

(define (decimal-string? value)
  (and (string? value)
       (not (string-null? value))
       (all char-numeric? (string->list value))))

(define (hex-string? value length)
  (and (string? value)
       (= (string-length value) length)
       (all (lambda (character)
              (or (char-numeric? character)
                  (and (char>=? character #\a)
                       (char<=? character #\f))))
            (string->list value))))

(define (safe-name? value)
  (and (string? value)
       (not (string-null? value))
       (not (member value '("." "..")))
       (all (lambda (character)
              (or (char-alphabetic? character)
                  (char-numeric? character)
                  (memv character '(#\- #\_ #\. #\:))))
            (string->list value))))

(define (normalized-absolute-path? path)
  (and (string? path)
       (string-prefix? "/" path)
       (not (string=? path "/"))
       (not (string-suffix? "/" path))
       (not (string-contains path "//"))
       (not (any (lambda (component)
                   (member component '("." ".." "")))
                 (cdr (string-split path #\/))))))

(define (store-item? path suffix)
  (and (normalized-absolute-path? path)
       (string-prefix? "/gnu/store/" path)
       (let* ((name (substring path (string-length "/gnu/store/")))
              (dash (string-index name #\-)))
         (and dash
              (= dash 32)
              (not (string-contains name "/"))
              (> (string-length name) 33)
              (all (lambda (character)
                     (string-index %guix-base32-alphabet character))
                   (string->list (substring name 0 dash)))
              (string-suffix? suffix name)))))

(define (alist-value alist key)
  (let ((entry (assq key alist)))
    (ensure entry "missing closed record: ~s" key)
    (cdr entry)))

(define (strictly-increasing-decimals? values)
  (let loop ((remaining values) (previous #f))
    (if (null? remaining)
        #t
        (let ((number (and (decimal-string? (car remaining))
                           (string->number (car remaining) 10))))
          (and number
               (or (not previous) (< previous number))
               (loop (cdr remaining) number))))))

(define (candidate-root? root)
  (and (list? root)
       (= (length root) 4)
       (let ((kind (list-ref root 0))
             (name (list-ref root 1))
             (subject (list-ref root 2))
             (target (list-ref root 3)))
         (and (string? kind)
              (string? name)
              (string=? kind "candidate")
              (decimal-string? subject)
              (string=? name (string-append "candidate-g" subject))
              (store-item? target "-system")))))

(define (bootcfg-root? root kind name)
  (and (list? root)
       (= (length root) 4)
       (let ((actual-kind (list-ref root 0))
             (actual-name (list-ref root 1))
             (subject (list-ref root 2))
             (target (list-ref root 3)))
         (and (string? actual-kind)
              (string? actual-name)
              (string? subject)
              (string=? actual-kind kind)
              (string=? actual-name name)
              (string=? subject "-")
              (store-item? target "-grub.cfg")))))

(define (sk:assert-boundary-manifest manifest)
  "Return MANIFEST after validating its closed, ordered D4a model."
  (ensure (list? manifest) "boundary manifest is not a list")
  (ensure (all (lambda (record)
                 (and (pair? record)
                      (symbol? (car record))))
               manifest)
          "boundary manifest contains a malformed record")
  (ensure (equal? (map car manifest) %manifest-keys)
          "boundary manifest keys or order differ from the closed model")
  (ensure (string=? (alist-value manifest 'schema) %manifest-schema)
          "boundary manifest schema is not ~a" %manifest-schema)
  (ensure (string=? (alist-value manifest 'mode) "FIXTURE-ONLY")
          "boundary manifest mode is not FIXTURE-ONLY")
  (ensure (string=? (alist-value manifest 'authorization) "NOT-GRANTED")
          "boundary manifest authorization is not NOT-GRANTED")
  (let* ((sha (alist-value manifest 'manifest-sha))
         (program (alist-value manifest 'program-root))
         (roots (alist-value manifest 'roots))
         (phases (alist-value manifest 'phases)))
    (ensure (hex-string? sha 64) "boundary manifest SHA256 is invalid")
    (ensure (and (list? program) (= (length program) 2))
            "program-root record has an invalid closed shape")
    (let ((path (car program))
          (target (cadr program)))
      (ensure
       (and (string? path)
            (string=? path
                      (string-append
                       "/var/guix/gcroots/p52b-system-prune-program-" sha)))
       "program-root path does not bind the manifest SHA256")
      (ensure (store-item? target "-system-pruning-loaded.scm")
              "program-root target is not a fused Scheme store item"))
    (ensure (and (list? roots) (>= (length roots) 3))
            "ordered recovery-root model is incomplete")
    (let* ((candidates (drop-right roots 2))
           (old (list-ref roots (- (length roots) 2)))
           (new (last roots)))
      (ensure (all candidate-root? candidates)
              "candidate roots do not match the closed model")
      (ensure
       (strictly-increasing-decimals? (map (lambda (root) (list-ref root 2))
                                           candidates))
       "candidate roots are not in strict generation order")
      (ensure (bootcfg-root? old "bootcfg-old" "old-bootcfg")
              "old bootcfg root is not the penultimate ordered root")
      (ensure (bootcfg-root? new "bootcfg-new" "new-bootcfg")
              "new bootcfg root is not the final ordered root")
      (ensure (not (string=? (list-ref old 3) (list-ref new 3)))
              "old and new bootcfg root targets are identical")
      (ensure (= (length (map cadr roots))
                 (length (delete-duplicates (map cadr roots))))
              "ordered recovery-root names are duplicated"))
    (ensure (and (list? phases) (pair? phases)
                 (all safe-name? phases))
            "boundary phase registry is empty or unsafe")
    (ensure (= (length phases) (length (delete-duplicates phases)))
            "boundary phase registry contains duplicate labels"))
  manifest)

(define (sk:boundary-roots manifest)
  (alist-value (sk:assert-boundary-manifest manifest) 'roots))

(define (event name subject)
  (list name subject))

(define (root-events name roots)
  (append-map
   (lambda (root)
     (let ((subject (cadr root)))
       (list (event (string-append name "-INTENT") subject)
             (event (string-append name "-DONE") subject))))
   roots))

(define (candidate-events name roots)
  (append-map
   (lambda (root)
     (let ((subject (list-ref root 2)))
       (list (event (string-append name "-INTENT") subject)
             (event (string-append name "-DONE") subject))))
   (drop-right roots 2)))

(define (forward-before-commit manifest)
  (let ((roots (sk:boundary-roots manifest)))
    (append
     (list (event "BEGIN" "-")
           (event "BACKUP-DONE" "-")
           (event "ROOTS-READY" "-")
           (event "GRUB-REPLACE-INTENT" "-")
           (event "GRUB-REPLACE-DONE" "-")
           (event "BOOTCFG-PROMOTE-INTENT" "-")
           (event "BOOTCFG-PROMOTE-DONE" "-"))
     (candidate-events "LINK-EXCLUDE" roots)
     (list (event "LINKS-STAGED" "-"))
     (candidate-events "LINK-DISCARD" roots)
     (list (event "LINKS-COMMITTED" "-")
           (event "POSTFLIGHT-VERIFIED" "-")))))

(define (cleanup-events manifest terminal)
  (append
   (root-events
    (if (string=? terminal "COMPLETE")
        "ROOT-REMOVE"
        "ROLLBACK-ROOT-REMOVE")
    (sk:boundary-roots manifest))
   (list (event terminal "-"))))

(define (rollback-events manifest forward-prefix)
  (let ((roots (sk:boundary-roots manifest)))
    (append
     (list (event "ROLLBACK-BEGIN" "-"))
     (candidate-events "LINK-RESTORE" roots)
     (list (event "LINKS-RESTORED" "-"))
     (if (member (event "GRUB-REPLACE-DONE" "-") forward-prefix)
         (list (event "GRUB-RESTORE-INTENT" "-")
               (event "GRUB-RESTORE-DONE" "-"))
         '())
     (if (member (event "BOOTCFG-PROMOTE-DONE" "-") forward-prefix)
         (list (event "BOOTCFG-RESTORE-INTENT" "-")
               (event "BOOTCFG-RESTORE-DONE" "-"))
         '())
     (list (event "PRESTATE-VERIFIED" "-"))
     (cleanup-events manifest "ROLLED-BACK"))))

(define (list-prefix? prefix whole)
  (and (<= (length prefix) (length whole))
       (equal? prefix (take whole (length prefix)))))

(define (byte-content value)
  (cond
   ((bytevector? value) value)
   ((string? value) (string->utf8 value))
   (else #f)))

(define (sk:exact-byte-prefix? candidate expected)
  "Return true only when CANDIDATE is a byte-exact prefix of EXPECTED."
  (let ((candidate-bytes (byte-content candidate))
        (expected-bytes (byte-content expected)))
    (and candidate-bytes
         expected-bytes
         (<= (bytevector-length candidate-bytes)
             (bytevector-length expected-bytes))
         (let loop ((index 0))
           (or (= index (bytevector-length candidate-bytes))
               (and (= (bytevector-u8-ref candidate-bytes index)
                       (bytevector-u8-ref expected-bytes index))
                    (loop (+ index 1))))))))

(define %construction-metadata-keys '(kind owner mode nlink size))

(define (sk:assert-construction-prefix label candidate expected metadata
                                       expected-owner expected-mode)
  "Validate one safe, single-link regular construction-file prefix."
  (ensure (and (list? metadata)
               (all pair? metadata)
               (equal? (map car metadata) %construction-metadata-keys))
          "~a construction metadata differs from the closed model" label)
  (ensure (eq? (alist-value metadata 'kind) 'regular)
          "~a construction path is not a regular file" label)
  (ensure (equal? (alist-value metadata 'owner) expected-owner)
          "~a construction owner differs" label)
  (ensure (equal? (alist-value metadata 'mode) expected-mode)
          "~a construction mode differs" label)
  (ensure (equal? (alist-value metadata 'nlink) 1)
          "~a construction file is not single-link" label)
  (let ((candidate-bytes (byte-content candidate)))
    (ensure (and candidate-bytes
                 (integer? (alist-value metadata 'size))
                 (= (alist-value metadata 'size)
                    (bytevector-length candidate-bytes)))
          "~a construction size differs from its bytes" label)
    (ensure (byte-content expected)
            "~a canonical construction bytes are not text or a bytevector"
            label))
  (ensure (sk:exact-byte-prefix? candidate expected)
          "~a construction bytes are not an exact canonical prefix" label)
  candidate)

(define %journal-trace-cache (make-parameter #f))

(define (deep-snapshot value)
  (cond
   ((pair? value)
    (cons (deep-snapshot (car value))
          (deep-snapshot (cdr value))))
   ((string? value) (string-copy value))
   (else value)))

(define (compute-legal-journal-traces manifest)
  (let* ((before (forward-before-commit manifest))
         (committed (append before (list (event "COMMITTED" "-"))))
         (cleanup (cleanup-events manifest "COMPLETE"))
         (rollback-traces
          (map (lambda (length)
                 (let ((prefix (take before length)))
                   (append prefix (rollback-events manifest prefix))))
               (iota (length before) 1))))
    (append
     (list (append committed cleanup))
     (map
      (lambda (length)
        (append committed
                (take cleanup length)
                (list (event "FORWARD-RECOVERY-BEGIN" "-"))
                (drop cleanup length)))
      (iota (length cleanup)))
     rollback-traces)))

(define (legal-journal-traces/internal manifest)
  (let* ((checked (sk:assert-boundary-manifest manifest))
         (cached (%journal-trace-cache)))
    (if (and cached (equal? (car cached) checked))
        (cdr cached)
        (compute-legal-journal-traces (deep-snapshot checked)))))

(define (sk:legal-journal-traces manifest)
  "Return a private copy of every legal forward, recovery, and rollback trace."
  (deep-snapshot (legal-journal-traces/internal manifest)))

(define (sk:call-with-journal-trace-cache manifest thunk)
  "Run THUNK with one dynamically scoped, immutable journal automaton.

The cache is confined to this call and keyed by a validated deep snapshot of
MANIFEST.  It cannot survive an engine invocation, accept later mutation, or
grow across transactions."
  (ensure (procedure? thunk)
          "journal-trace cache continuation is not a procedure")
  (let* ((checked (sk:assert-boundary-manifest manifest))
         (snapshot (deep-snapshot checked))
         (traces (compute-legal-journal-traces snapshot)))
    (parameterize ((%journal-trace-cache (cons snapshot traces)))
      (thunk))))

(define (valid-event-shape? item)
  (and (list? item)
       (= (length item) 2)
       (string? (car item))
       (string? (cadr item))
       (not (string-null? (car item)))
       (not (string-null? (cadr item)))))

(define (sk:legal-journal-prefix? manifest history)
  (and (list? history)
       (pair? history)
       (all valid-event-shape? history)
       (any (lambda (trace) (list-prefix? history trace))
            (legal-journal-traces/internal manifest))))

(define (sk:journal-legal-successors manifest history)
  "Return the unique set of events that may legally follow HISTORY."
  (ensure (sk:legal-journal-prefix? manifest history)
          "journal history is not a legal closed-trace prefix")
  (deep-snapshot
   (delete-duplicates
    (filter-map
     (lambda (trace)
       (and (list-prefix? history trace)
            (< (length history) (length trace))
            (list-ref trace (length history))))
     (legal-journal-traces/internal manifest)))))

(define (sk:journal-head manifest history)
  "Return the final event of a validated, non-empty journal HISTORY."
  (last (sk:assert-legal-journal-history manifest history)))

(define (sk:journal-history-status manifest history)
  "Classify validated HISTORY as begin, active, or terminal."
  (let ((head (car (sk:journal-head manifest history))))
    (cond
     ((and (= (length history) 1) (string=? head "BEGIN")) 'begin)
     ((member head '("COMPLETE" "ROLLED-BACK")) 'terminal)
     (else 'active))))

(define (sk:assert-legal-journal-history manifest history)
  (ensure (sk:legal-journal-prefix? manifest history)
          "journal history is not a legal closed-trace prefix")
  history)

(define (sk:assert-legal-journal-successor manifest history successor)
  (ensure (valid-event-shape? successor)
          "proposed journal successor has an invalid shape")
  (ensure (member successor (sk:journal-legal-successors manifest history))
          "proposed journal successor is illegal: ~s" successor)
  successor)

(define (journal-header manifest)
  (let ((sha (alist-value (sk:assert-boundary-manifest manifest)
                          'manifest-sha)))
    (list
     (list "schema" %journal-schema)
     (list "manifest" sha)
     (list "mode" "FIXTURE-ONLY")
     (list "transaction" sha))))

(define (tsv-line fields)
  (string-append (string-join fields "\t") "\n"))

(define (journal-header-text manifest)
  (string-concatenate (map tsv-line (journal-header manifest))))

(define (journal-payload sequence event subject previous)
  (string-join
   (list (number->string sequence) event subject previous)
   "\t"))

(define (journal-record sequence event subject previous)
  (let ((payload (journal-payload sequence event subject previous)))
    (list "event"
          (number->string sequence)
          event
          subject
          previous
          (string-sha256 payload))))

(define (strict-tsv-records text)
  (ensure (and (string? text)
               (not (string-null? text))
               (string-suffix? "\n" text)
               (not (string-index text #\return))
               (not (string-index text #\nul)))
          "journal bytes are not canonical LF-terminated text")
  (let ((lines (drop-right (string-split text #\newline) 1)))
    (ensure (and (pair? lines)
                 (all (lambda (line) (not (string-null? line))) lines))
            "journal contains an empty or incomplete row")
    (map (lambda (line) (string-split line #\tab)) lines)))

(define (sk:render-journal manifest history)
  "Render validated D4 HISTORY as the canonical SHA-256 journal chain."
  (sk:assert-legal-journal-history manifest history)
  (let loop ((remaining history)
             (sequence 1)
             (previous (string-sha256 (journal-header-text manifest)))
             (records '()))
    (if (null? remaining)
        (string-append
         (journal-header-text manifest)
         (string-concatenate (map tsv-line (reverse records))))
        (let* ((item (car remaining))
               (record
                (journal-record sequence (car item) (cadr item) previous)))
          (loop (cdr remaining)
                (+ sequence 1)
                (list-ref record 5)
                (cons record records))))))

(define (sk:parse-journal manifest text)
  "Parse TEXT as one complete, non-empty, hash-valid D4 journal HISTORY."
  (let* ((header (journal-header manifest))
         (records (strict-tsv-records text)))
    (ensure (> (length records) (length header))
            "durable journal has no event history")
    (ensure (equal? (take records (length header)) header)
            "journal header or identity differs from the closed D4 contract")
    (let loop ((remaining (drop records (length header)))
               (sequence 1)
               (previous (string-sha256 (journal-header-text manifest)))
               (history '()))
      (if (null? remaining)
          (sk:assert-legal-journal-history manifest (reverse history))
          (let ((record (car remaining)))
            (ensure (and (= (length record) 6)
                         (string=? (car record) "event"))
                    "journal event row has an invalid closed shape")
            (let* ((sequence-text (list-ref record 1))
                   (event (list-ref record 2))
                   (subject (list-ref record 3))
                   (prior (list-ref record 4))
                   (digest (list-ref record 5))
                   (payload
                    (journal-payload sequence event subject prior)))
              (ensure (string=? sequence-text (number->string sequence))
                      "journal sequence is missing, duplicated, or non-canonical")
              (ensure (string=? prior previous)
                      "journal hash-chain predecessor differs")
              (ensure (string=? digest (string-sha256 payload))
                      "journal event digest differs")
              (loop (cdr remaining)
                    (+ sequence 1)
                    digest
                    (cons (list event subject) history))))))))

(define (sk:append-journal-event manifest text successor)
  "Append unique legal SUCCESSOR to validated D4 journal TEXT."
  (let* ((history (sk:parse-journal manifest text))
         (successors (sk:journal-legal-successors manifest history)))
    (sk:assert-legal-journal-successor manifest history successor)
    (ensure (= (count (lambda (candidate)
                        (equal? candidate successor))
                      successors)
               1)
            "journal successor is not unique in the closed D4 automaton")
    (let* ((expected (append history (list successor)))
           (rendered (sk:render-journal manifest expected)))
      (ensure (equal? (sk:parse-journal manifest rendered) expected)
              "rendered journal append did not re-parse exactly")
      rendered)))

(define %bootstrap-snapshot-keys
  '(protected? foreign? program-root transaction-base transaction-lock
    system-lock root-namespace durable-roots transaction-dir quarantine
    journal journal-history live-grub live-bootcfg grub-temporary
    bootcfg-temporary backup))

(define (review reason)
  (list "REVIEW-REQUIRED" reason '()))

(define (resume next locks)
  (list "RESUME" next locks))

(define (all-absent? values)
  (all (lambda (value)
         (or (eq? value 'absent)
             (and (list? value) (null? value))))
       values))

(define (history-has? history name)
  (any (lambda (item) (string=? (car item) name)) history))

(define (expected-rollback-bootcfg-states history)
  (cond
   ((history-has? history "BOOTCFG-PROMOTE-DONE") '(new))
   ((history-has? history "BOOTCFG-PROMOTE-INTENT") '(old new))
   (else '(old))))

(define (known-temporary-state? history live-grub live-bootcfg
                                grub-temporary bootcfg-temporary)
  (let ((head (and (pair? history) (car (last history)))))
    (cond
     ((and (eq? grub-temporary 'absent)
           (eq? bootcfg-temporary 'absent))
      #t)
     ((not (eq? bootcfg-temporary 'absent))
      (and (eq? grub-temporary 'absent)
           (case bootcfg-temporary
             ((exact-new)
              (and (string=? head "BOOTCFG-PROMOTE-INTENT")
                   (eq? live-grub 'new)
                   (eq? live-bootcfg 'old)))
             ((exact-old)
              (and (history-has? history "BOOTCFG-PROMOTE-INTENT")
                   (string=? head "BOOTCFG-RESTORE-INTENT")
                   (eq? live-grub 'old)
                   (eq? live-bootcfg 'new)))
             (else #f))))
     (else
      (case grub-temporary
        ((exact-new)
         (and (string=? head "GRUB-REPLACE-INTENT")
              (eq? live-grub 'old)
              (eq? live-bootcfg 'old)))
        ((exact-old)
         (and (history-has? history "GRUB-REPLACE-INTENT")
              (string=? head "GRUB-RESTORE-INTENT")
              (eq? live-grub 'new)
              (member live-bootcfg
                      (expected-rollback-bootcfg-states history))))
        (else #f))))))

(define (bootstrap-classification manifest snapshot)
  (ensure (and (list? snapshot)
               (equal? (map car snapshot) %bootstrap-snapshot-keys))
          "bootstrap snapshot differs from the closed model")
  (let* ((protected? (alist-value snapshot 'protected?))
         (foreign? (alist-value snapshot 'foreign?))
         (program (alist-value snapshot 'program-root))
         (base (alist-value snapshot 'transaction-base))
         (transaction-lock (alist-value snapshot 'transaction-lock))
         (system-lock (alist-value snapshot 'system-lock))
         (namespace (alist-value snapshot 'root-namespace))
         (durable (alist-value snapshot 'durable-roots))
         (transaction-dir (alist-value snapshot 'transaction-dir))
         (quarantine (alist-value snapshot 'quarantine))
         (journal (alist-value snapshot 'journal))
         (journal-history (alist-value snapshot 'journal-history))
         (live-grub (alist-value snapshot 'live-grub))
         (live-bootcfg (alist-value snapshot 'live-bootcfg))
         (grub-temporary (alist-value snapshot 'grub-temporary))
         (bootcfg-temporary (alist-value snapshot 'bootcfg-temporary))
         (backup (alist-value snapshot 'backup))
         (expected-roots (map cadr (sk:boundary-roots manifest)))
         (later (list base transaction-lock system-lock namespace durable
                      transaction-dir quarantine journal grub-temporary
                      bootcfg-temporary backup))
         (temporaries-absent?
          (and (eq? grub-temporary 'absent)
               (eq? bootcfg-temporary 'absent)))
         (temporary-count
          (count (lambda (state) (not (eq? state 'absent)))
                 (list grub-temporary bootcfg-temporary))))
    (ensure (boolean? protected?) "protected-state flag is not boolean")
    (ensure (boolean? foreign?) "foreign-state flag is not boolean")
    (ensure (member program '(absent exact foreign))
            "program-root state is invalid")
    (ensure (all (lambda (state) (member state '(absent exact foreign)))
                 (list base transaction-lock system-lock namespace
                       transaction-dir quarantine))
            "bootstrap path state is invalid")
    (ensure (list? durable) "durable-root prefix is not a list")
    (ensure (member journal
                    '(absent initial-temp-prefix initial-temp-equal begin
                      active terminal foreign))
            "initial-journal state is invalid")
    (ensure (list? journal-history)
            "journal history is not a list")
    (ensure (member live-grub '(old new foreign))
            "live GRUB state is invalid")
    (ensure (member live-bootcfg '(old new foreign))
            "live bootcfg state is invalid")
    (ensure (member grub-temporary
                    '(absent exact-old exact-new foreign))
            "GRUB temporary state is invalid")
    (ensure (member bootcfg-temporary
                    '(absent exact-old exact-new foreign))
            "bootcfg temporary state is invalid")
    (ensure (member backup '(absent partial-prefix exact done foreign))
            "backup state is invalid")
    (cond
     ((not protected?) (review "protected surfaces drifted"))
     (foreign? (review "foreign bootstrap state is present"))
     ((or (eq? program 'foreign)
          (member 'foreign (list base transaction-lock system-lock namespace
                                 transaction-dir quarantine journal
                                 live-grub live-bootcfg
                                 grub-temporary bootcfg-temporary backup)))
      (review "a bootstrap path has foreign state"))
     ((> temporary-count 1)
      (review "multiple transaction temporaries are present"))
     ((eq? program 'absent)
      (if (all-absent? later)
          (list "INITIAL-ELIGIBLE" "program-temporary-root" '())
          (review "persistent bootstrap state exists without the program root")))
     ((eq? base 'absent)
      (if (all-absent? (cdr later))
          (resume "transaction-base" '())
          (review "state skips the transaction-base prefix")))
     ((eq? transaction-lock 'absent)
      (if (all-absent? (drop later 2))
          (resume "transaction-lock" '())
          (review "state skips the transaction-lock prefix")))
     ((eq? system-lock 'absent)
      (if (all-absent? (drop later 3))
          (resume "system-lock" '("transaction-lock"))
          (review "state skips the System-lock prefix")))
     ((eq? namespace 'absent)
      (if (all-absent? (drop later 4))
          (resume "root-namespace" '("transaction-lock" "system-lock"))
          (review "state skips the durable-root namespace prefix")))
     ((not (list-prefix? durable expected-roots))
      (review "durable roots are not one exact ordered prefix"))
     ((< (length durable) (length expected-roots))
      (if (all-absent? (list transaction-dir quarantine journal
                             grub-temporary bootcfg-temporary backup))
          (resume (string-append
                   "durable-root:"
                   (list-ref expected-roots (length durable)))
                  '("transaction-lock" "system-lock"))
          (review "state skips an ordered durable-root prefix")))
     ((eq? transaction-dir 'absent)
      (if (all-absent? (list quarantine journal grub-temporary
                             bootcfg-temporary backup))
          (resume "transaction-directory"
                  '("transaction-lock" "system-lock"))
          (review "state skips the transaction-directory prefix")))
     ((eq? quarantine 'absent)
      (if (all-absent? (list journal grub-temporary bootcfg-temporary backup))
          (resume "quarantine" '("transaction-lock" "system-lock"))
          (review "state skips the quarantine prefix")))
     ((eq? journal 'absent)
      (if (and (null? journal-history)
               temporaries-absent?
               (eq? backup 'absent))
          (resume "initial-journal" '("transaction-lock" "system-lock"))
          (review "history, backup, or temporary exists before the journal")))
     ((member journal '(initial-temp-prefix initial-temp-equal))
      (if (and (null? journal-history)
               temporaries-absent?
               (eq? backup 'absent))
          (resume "reconcile-initial-journal"
                  '("transaction-lock" "system-lock"))
          (review
           "history, backup, or temporary exists beside an incomplete journal")))
     ((eq? journal 'begin)
      (if (or (not (equal? journal-history '(("BEGIN" "-"))))
              (not temporaries-absent?)
              (not (and (eq? live-grub 'old)
                        (eq? live-bootcfg 'old))))
          (review "BEGIN history or live surfaces are not exact")
          (case backup
        ((absent)
         (resume "old-grub-backup" '("transaction-lock" "system-lock")))
        ((partial-prefix)
         (resume "replace-partial-backup"
                 '("transaction-lock" "system-lock")))
        ((exact)
         (resume "append-BACKUP-DONE"
                 '("transaction-lock" "system-lock")))
        (else (review "BEGIN has an impossible backup state")))))
     ((member journal '(active terminal))
      (if (and (eq? backup 'done)
               (catch sk:boundary-error-key
                 (lambda ()
                   (eq? (sk:journal-history-status manifest journal-history)
                        journal))
                 (lambda _ #f))
               (if (eq? journal 'terminal)
                   (and temporaries-absent?
                        (let ((head (car (last journal-history))))
                          (if (string=? head "COMPLETE")
                              (and (eq? live-grub 'new)
                                   (eq? live-bootcfg 'new))
                              (and (eq? live-grub 'old)
                                   (eq? live-bootcfg 'old)))))
                   (known-temporary-state?
                    journal-history live-grub live-bootcfg
                    grub-temporary bootcfg-temporary)))
          (list "JOURNAL-RECOVERY" (symbol->string journal)
                '("transaction-lock" "system-lock"))
          (review
           "active/terminal journal history, live surfaces, backup, or temporary differ")))
     (else (review "unrecognized bootstrap construction state")))))

(define (sk:classify-bootstrap manifest snapshot)
  "Classify a persistent program-root-first construction snapshot."
  (catch sk:boundary-error-key
    (lambda () (bootstrap-classification manifest snapshot))
    (lambda (_key message) (review message))))

(define %legacy-snapshot-keys
  '(protected? foreign? program-root roots transaction-dir quarantine
    journal-temp backup))

(define (legacy-classification snapshot)
  (ensure (and (list? snapshot)
               (equal? (map car snapshot) %legacy-snapshot-keys))
          "legacy snapshot differs from the closed model")
  (let ((protected? (alist-value snapshot 'protected?))
        (foreign? (alist-value snapshot 'foreign?))
        (program (alist-value snapshot 'program-root))
        (roots (alist-value snapshot 'roots))
        (transaction-dir (alist-value snapshot 'transaction-dir))
        (quarantine (alist-value snapshot 'quarantine))
        (journal-temp (alist-value snapshot 'journal-temp))
        (backup (alist-value snapshot 'backup)))
    (ensure (boolean? protected?) "legacy protected-state flag is not boolean")
    (ensure (boolean? foreign?) "legacy foreign-state flag is not boolean")
    (cond
     ((not protected?) (review "legacy protected surfaces drifted"))
     (foreign? (review "legacy foreign state is present"))
     ((not (eq? program 'absent))
      (review "legacy rootless classifier received a program root"))
     ((not (and (list? roots) (null? roots)))
      (review "legacy rootless classifier received recovery roots"))
     ((not (member transaction-dir '(absent exact)))
      (review "legacy transaction directory has unsafe state"))
     ((not (member quarantine '(absent exact)))
      (review "legacy quarantine has unsafe state"))
     ((not (member journal-temp '(absent prefix equal foreign)))
      (review "legacy journal temporary has unsafe state"))
     ((not (member backup '(absent foreign)))
      (review "legacy backup has unsafe state"))
     ((or (eq? journal-temp 'foreign) (eq? backup 'foreign))
      (review "legacy construction bytes are not a canonical prefix"))
     ((eq? transaction-dir 'absent)
      (if (and (eq? quarantine 'absent)
               (eq? journal-temp 'absent)
               (eq? backup 'absent))
          (list "NO-LEGACY-GAP" "-" '())
          (review "legacy children exist without a transaction directory")))
     ((eq? quarantine 'absent)
      (if (and (eq? journal-temp 'absent) (eq? backup 'absent))
          (resume "remove-empty-transaction-directory" '())
          (review "legacy construction skips the empty quarantine")))
     ((member journal-temp '(prefix equal))
      (if (eq? backup 'absent)
          (resume "reconcile-legacy-initial-journal" '())
          (review "legacy backup accompanies an initial-journal temporary")))
     ((and (eq? journal-temp 'absent) (eq? backup 'absent))
      (resume "remove-empty-quarantine-and-directory" '()))
     (else (review "legacy construction state is ambiguous")))))

(define (sk:classify-legacy-gap snapshot)
  "Classify only the three explicitly synthetic, rootless D3-gap rows."
  (catch sk:boundary-error-key
    (lambda () (legacy-classification snapshot))
    (lambda (_key message) (review message))))

(define (assert-guard-set guards)
  (ensure (and (list? guards)
               (equal? (map car guards) %guard-keys))
          "pre-phase guards differ from the closed callback set")
  (for-each
   (lambda (entry)
     (ensure (procedure? (cdr entry))
             "pre-phase guard is not a procedure: ~s" (car entry)))
   guards))

(define (sk:call-with-pre-phase-gate manifest phase state guards thunk)
  "Run THUNK only after all five central D4a guards accept PHASE."
  (sk:assert-boundary-manifest manifest)
  (ensure (member phase (alist-value manifest 'phases))
          "phase is absent from the closed registry: ~a" phase)
  (ensure (procedure? thunk) "pre-phase continuation is not a procedure")
  (assert-guard-set guards)
  (for-each
   (lambda (key)
     (let ((accepted? ((alist-value guards key) manifest phase state)))
       (ensure (eq? accepted? #t)
               "pre-phase ~a guard refused phase ~a" key phase)))
   %guard-keys)
  (thunk))

(define (sk:terminal-cleanup-plan manifest terminal)
  "Return the only legal durable-root/terminal/program-root cleanup order."
  (ensure (member terminal '("COMPLETE" "ROLLED-BACK"))
          "invalid terminal cleanup event: ~s" terminal)
  (let ((program (alist-value (sk:assert-boundary-manifest manifest)
                              'program-root)))
    (append
     (map (lambda (root) (list "remove-root" (cadr root)))
          (sk:boundary-roots manifest))
     (list (list "remove-root-namespace" "-")
           (list "append-terminal" terminal)
           (list "remove-program-root" (car program))))))

(define (sk:assert-terminal-cleanup-prefix manifest terminal completed)
  "Accept only an interruption prefix of the exact terminal cleanup plan."
  (let ((plan (sk:terminal-cleanup-plan manifest terminal)))
    (ensure (and (list? completed)
                 (list-prefix? completed plan))
            "terminal cleanup does not follow the exact root-last order")
    completed))
