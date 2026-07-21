;;; Pure fail-closed live reconciliation classifier for P5.2b-D4c.1a.

(define-module (sk system-pruning-live-reconciliation)
  #:use-module (gcrypt hash)
  #:use-module (guix base16)
  #:use-module (rnrs bytevectors)
  #:use-module ((sk system-pruning-live-boundary) #:prefix boundary:)
  #:use-module (srfi srfi-1)
  #:export (sk:live-reconciliation-error-key
            sk:live-reconciliation-observation-keys
            sk:assert-live-reconciliation-observation
            sk:render-live-reconciliation-observation
            sk:live-reconciliation-observation-sha256
            sk:classify-live-reconciliation
            sk:live-reconciliation-required-grant
            sk:live-reconciliation-direction
            sk:live-reconciliation-next-phase
            sk:live-reconciliation-grant-binding))

(define sk:live-reconciliation-error-key
  'sk-system-pruning-live-reconciliation)

(define %observation-schema
  "p5.2b-system-prune-live-reconciliation-observation/v1")

(define sk:live-reconciliation-observation-keys
  '(protected? foreign? selected-links program-root transaction-base
    transaction-lock system-lock recovery-root-base root-namespace
    durable-roots transaction-dir quarantine quarantine-entries journal
    journal-history live-grub live-bootcfg grub-temporary bootcfg-temporary
    backup))

(define (%fail format-string . arguments)
  (throw sk:live-reconciliation-error-key
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

(define (alist-value alist key)
  (let ((entry (assq key alist)))
    (ensure entry "missing live reconciliation record: ~s" key)
    (cdr entry)))

(define (review reason)
  (list "REVIEW-REQUIRED" reason '()))

(define (resume next locks)
  (list "RESUME" next locks))

(define (ascii-digit? character)
  (and (char>=? character #\0)
       (char<=? character #\9)))

(define (canonical-positive-decimal? value)
  (and (string? value)
       (not (string-null? value))
       (not (char=? (string-ref value 0) #\0))
       (all ascii-digit? (string->list value))))

(define (durable-root-phase? phase)
  (and (string? phase)
       (string-prefix? "durable-root:" phase)
       (let ((name (substring phase (string-length "durable-root:"))))
         (or (member name '("old-bootcfg" "new-bootcfg"))
             (and (string-prefix? "candidate-g" name)
                  (canonical-positive-decimal?
                   (substring name (string-length "candidate-g"))))))))

(define (bootstrap-phase-locks phase)
  (cond
   ((member phase '("transaction-base" "transaction-lock")) '())
   ((string=? phase "system-lock") '("transaction-lock"))
   ((or (member phase '("recovery-root-base"
                        "root-namespace"
                        "transaction-directory"
                        "quarantine"
                        "initial-journal"))
        (durable-root-phase? phase))
    '("transaction-lock" "system-lock"))
   (else #f)))

(define (assert-classification classification)
  (ensure (and (list? classification)
               (= (length classification) 3)
               (string? (car classification))
               (string? (cadr classification))
               (list? (caddr classification))
               (all string? (caddr classification)))
          "live reconciliation classification has an invalid shape")
  (let ((name (car classification))
        (detail (cadr classification))
        (locks (caddr classification)))
    (cond
     ((string=? name "INITIAL-ELIGIBLE")
      (ensure (and (string=? detail "program-temporary-root")
                   (null? locks))
              "initial classification differs from the closed form"))
     ((string=? name "RESUME")
      (let ((expected-locks (bootstrap-phase-locks detail)))
        (ensure (and expected-locks (equal? locks expected-locks))
                "bootstrap classification phase or lock set is invalid")))
     ((string=? name "REVIEW-REQUIRED")
      (ensure (and (not (string-null? detail)) (null? locks))
              "review classification differs from the closed form"))
     (else
      (%fail "unknown live reconciliation classification: ~s"
             classification))))
  classification)

(define (list-prefix? prefix whole)
  (and (<= (length prefix) (length whole))
       (equal? prefix (take whole (length prefix)))))

(define (all-absent? values)
  (all (lambda (value)
         (or (eq? value 'absent)
             (and (list? value) (null? value))))
       values))

(define (sk:assert-live-reconciliation-observation boundary observation)
  "Validate one normalized, read-only observation without classifying it."
  (boundary:sk:assert-live-boundary boundary)
  (ensure (and (list? observation)
               (all pair? observation)
               (equal? (map car observation)
                       sk:live-reconciliation-observation-keys))
          "live reconciliation observation differs from the closed model")
  (ensure (boolean? (alist-value observation 'protected?))
          "protected-state flag is not boolean")
  (ensure (boolean? (alist-value observation 'foreign?))
          "foreign-state flag is not boolean")
  (ensure (member (alist-value observation 'selected-links)
                  '(prestate changed foreign))
          "selected-link state is invalid")
  (ensure (member (alist-value observation 'program-root)
                  '(absent exact foreign))
          "program-root state is invalid")
  (for-each
   (lambda (key)
     (ensure (member (alist-value observation key)
                     '(absent exact foreign))
             "live path state is invalid: ~a" key))
   '(transaction-base transaction-lock system-lock recovery-root-base
     root-namespace transaction-dir quarantine))
  (let ((durable (alist-value observation 'durable-roots)))
    (ensure (and (list? durable) (all string? durable))
            "durable-root prefix is not a string list")
    (ensure (= (length durable) (length (delete-duplicates durable)))
            "durable-root observation contains duplicate names"))
  (ensure (member (alist-value observation 'journal)
                  '(absent initial-temp-prefix initial-temp-equal begin
                    active terminal foreign))
          "live journal state is invalid")
  (ensure (member (alist-value observation 'quarantine-entries)
                  '(absent empty occupied foreign))
          "quarantine-entry state is invalid")
  (ensure (list? (alist-value observation 'journal-history))
          "live journal history is not a list")
  (ensure (member (alist-value observation 'live-grub) '(old new foreign))
          "live GRUB state is invalid")
  (ensure (member (alist-value observation 'live-bootcfg) '(old new foreign))
          "live bootcfg state is invalid")
  (ensure (member (alist-value observation 'grub-temporary)
                  '(absent exact-old exact-new foreign))
          "GRUB temporary state is invalid")
  (ensure (member (alist-value observation 'bootcfg-temporary)
                  '(absent exact-old exact-new foreign))
          "bootcfg temporary state is invalid")
  (ensure (member (alist-value observation 'backup)
                  '(absent partial-prefix exact done foreign))
          "old-GRUB backup state is invalid")
  observation)

(define (safe-observation-field value)
  (ensure (and (string? value)
               (not (string-null? value))
               (not (string-index value #\tab))
               (not (string-index value #\newline))
               (not (string-index value #\return))
               (not (string-index value #\nul)))
          "live reconciliation observation field is unsafe")
  value)

(define (render-observation-value value)
  (cond
   ((boolean? value) (if value "TRUE" "FALSE"))
   ((symbol? value) (symbol->string value))
   ((and (list? value) (null? value)) "-")
   ((and (list? value) (all string? value))
    (string-join value ","))
   ((and (list? value)
         (all (lambda (event)
                (and (list? event) (= (length event) 2)
                     (all string? event)))
              value))
    (string-join (map (lambda (event) (string-join event ":")) value)
                 ","))
   (else (%fail "cannot render live reconciliation observation value: ~s"
                value))))

(define (sk:render-live-reconciliation-observation boundary observation)
  "Render one validated normalized observation as canonical LF TSV."
  (let ((checked
         (sk:assert-live-reconciliation-observation boundary observation)))
    (string-append
     "schema\t" %observation-schema "\n"
     (string-concatenate
      (map (lambda (entry)
             (let ((value (safe-observation-field
                           (render-observation-value (cdr entry)))))
               (string-append (symbol->string (car entry))
                              "\t" value "\n")))
           checked)))))

(define (sk:live-reconciliation-observation-sha256 boundary observation)
  "Return SHA256 of the exact canonical normalized observation."
  (string-sha256
   (sk:render-live-reconciliation-observation boundary observation)))

(define (sk:classify-live-reconciliation boundary observation)
  "Classify one normalized live observation; perform no effect.

The caller owns all lstat, byte, store, root, lock, and protected-surface
observations.  This checkpoint accepts only one exact pre-journal bootstrap
prefix.  Initial-journal construction and durable-journal recovery remain
deferred and REVIEW-REQUIRED."
  (let* ((snapshot
          (sk:assert-live-reconciliation-observation boundary observation))
         (protected? (alist-value snapshot 'protected?))
         (foreign? (alist-value snapshot 'foreign?))
         (selected-links (alist-value snapshot 'selected-links))
         (program (alist-value snapshot 'program-root))
         (base (alist-value snapshot 'transaction-base))
         (transaction-lock (alist-value snapshot 'transaction-lock))
         (system-lock (alist-value snapshot 'system-lock))
         (root-base (alist-value snapshot 'recovery-root-base))
         (namespace (alist-value snapshot 'root-namespace))
         (durable (alist-value snapshot 'durable-roots))
         (transaction-dir (alist-value snapshot 'transaction-dir))
         (quarantine (alist-value snapshot 'quarantine))
         (quarantine-entries (alist-value snapshot 'quarantine-entries))
         (journal (alist-value snapshot 'journal))
         (history (alist-value snapshot 'journal-history))
         (live-grub (alist-value snapshot 'live-grub))
         (live-bootcfg (alist-value snapshot 'live-bootcfg))
         (grub-temporary (alist-value snapshot 'grub-temporary))
         (bootcfg-temporary (alist-value snapshot 'bootcfg-temporary))
         (backup (alist-value snapshot 'backup))
         (expected-roots
          (map cadr (boundary:sk:live-boundary-roots boundary)))
         (later (list base transaction-lock system-lock root-base namespace
                      durable transaction-dir quarantine journal
                      grub-temporary bootcfg-temporary backup))
         (temporaries-absent?
          (and (eq? grub-temporary 'absent)
               (eq? bootcfg-temporary 'absent)))
         (temporary-count
          (count (lambda (state) (not (eq? state 'absent)))
                 (list grub-temporary bootcfg-temporary))))
    (cond
     ((not protected?) (review "protected surfaces drifted"))
     (foreign? (review "foreign live state is present"))
     ((not (eq? selected-links 'prestate))
      (review "selected System links differ from the exact prestate"))
     ((or (eq? program 'foreign)
          (member 'foreign
                  (list base transaction-lock system-lock root-base namespace
                        transaction-dir quarantine journal live-grub
                        live-bootcfg grub-temporary bootcfg-temporary backup)))
      (review "a live transaction surface has foreign state"))
     ((eq? quarantine-entries 'foreign)
      (review "quarantine contains foreign state"))
     ((or (and (eq? quarantine 'absent)
               (not (eq? quarantine-entries 'absent)))
          (and (eq? quarantine 'exact)
               (not (eq? quarantine-entries 'empty))))
      (review "quarantine path and entry state are inconsistent"))
     ((not (and (eq? live-grub 'old) (eq? live-bootcfg 'old)))
      (review "pre-journal GRUB or bootcfg state differs from prestate"))
     ((or (and (member journal
                       '(absent initial-temp-prefix initial-temp-equal))
               (pair? history))
          (and (eq? journal 'begin)
               (not (equal? history '(("BEGIN" "-"))))))
      (review "journal state and history are inconsistent"))
     ((> temporary-count 1)
      (review "multiple transaction temporaries are present"))
     ((eq? program 'absent)
      (if (all-absent? later)
          (list "INITIAL-ELIGIBLE" "program-temporary-root" '())
          (review "persistent transaction state exists without program root")))
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
     ((eq? root-base 'absent)
      (if (all-absent? (drop later 4))
          (resume "recovery-root-base"
                  '("transaction-lock" "system-lock"))
          (review "state skips the recovery-root base prefix")))
     ((eq? namespace 'absent)
      (if (all-absent? (drop later 5))
          (resume "root-namespace" '("transaction-lock" "system-lock"))
          (review "state skips the recovery-root namespace prefix")))
     ((not (list-prefix? durable expected-roots))
      (review "durable roots are not one exact ordered prefix"))
     ((< (length durable) (length expected-roots))
      (if (all-absent? (list transaction-dir quarantine journal
                             grub-temporary bootcfg-temporary backup))
          (resume
           (string-append
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
      (if (and (null? history)
               temporaries-absent?
               (eq? backup 'absent))
          (resume "initial-journal" '("transaction-lock" "system-lock"))
          (review "history, backup, or temporary exists before journal")))
     ((member journal '(initial-temp-prefix initial-temp-equal))
      (review "initial-journal construction recovery is not yet frozen"))
     ((member journal '(begin active terminal))
      ;; Phase-specific link/quarantine and terminal policies belong to the
      ;; later production adapter checkpoint.  Until those records exist,
      ;; every durable-journal state remains review-only without a grant.
      (review "durable-journal recovery policy is not yet frozen"))
     (else (review "unrecognized live reconciliation state")))))

(define (sk:live-reconciliation-required-grant classification)
  "Return execution, recovery, or none for one classifier result."
  (let ((checked (assert-classification classification)))
    (cond
     ((string=? (car checked) "INITIAL-ELIGIBLE") 'execution)
     ((string=? (car checked) "RESUME") 'recovery)
     (else 'none))))

(define (sk:live-reconciliation-direction classification history)
  "Return the closed recovery direction for CLASSIFICATION and HISTORY."
  (ensure (list? history) "reconciliation history is not a list")
  (let ((grant (sk:live-reconciliation-required-grant classification)))
    (cond
     ((eq? grant 'execution) "INITIAL")
     ((eq? grant 'none) "NONE")
     ((string=? (car classification) "RESUME")
      (ensure (null? history)
              "pre-journal bootstrap direction has durable history")
      "BOOTSTRAP")
     (else (%fail "classification has no frozen direction: ~s"
                  classification)))))

(define (sk:live-reconciliation-next-phase classification)
  "Return the exact bootstrap phase, or #f for journal-owned continuation."
  (case (sk:live-reconciliation-required-grant classification)
    ((execution recovery)
     (cadr classification))
    (else #f)))

(define (sk:live-reconciliation-grant-binding boundary classification
                                                 observation)
  "Return the exact recovery-token suffix for one accepted bootstrap prefix."
  (let ((current
         (sk:classify-live-reconciliation boundary observation)))
    (ensure (equal? current classification)
            "classification differs from the supplied observation")
    (ensure (eq? (sk:live-reconciliation-required-grant classification)
                 'recovery)
            "observation is not eligible for a recovery grant")
    (ensure (eq? (alist-value observation 'journal) 'absent)
            "bootstrap grant binding has a journal surface")
    `((observed-journal-head . "ABSENT")
      (observed-state-sha256
       . ,(sk:live-reconciliation-observation-sha256
           boundary observation))
      (direction . "BOOTSTRAP")
      (next-phase . ,(sk:live-reconciliation-next-phase classification)))))
