;;; Deterministic tests for the pure P5.2b-D4a boundary safety model.

(use-modules (gcrypt hash)
             (guix base16)
             (rnrs bytevectors)
             (srfi srfi-1)
             (sk system-pruning-boundary))

(define %program "guix-system-pruning-boundary-check")
(define %sha (make-string 64 #\a))
(define %program-target
  "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system-pruning-loaded.scm")

(define %phases
  '("program-temporary-root"
    "program-root"
    "transaction-base"
    "transaction-lock"
    "system-lock"
    "durable-root:candidate-g1"
    "grub-replace"
    "bootcfg-promote"
    "link-exclude:1"
    "journal-COMMITTED"
    "journal-COMPLETE"
    "program-root-remove"))

(define %manifest
  `((schema . "p5.2b-system-prune-boundary/v1")
    (mode . "FIXTURE-ONLY")
    (authorization . "NOT-GRANTED")
    (manifest-sha . ,%sha)
    (program-root
     . (,(string-append
          "/var/guix/gcroots/p52b-system-prune-program-" %sha)
        ,%program-target))
    (roots
     . (("candidate" "candidate-g1" "1"
         "/gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-system")
        ("candidate" "candidate-g2" "2"
         "/gnu/store/cccccccccccccccccccccccccccccccc-system")
        ("bootcfg-old" "old-bootcfg" "-"
         "/gnu/store/dddddddddddddddddddddddddddddddd-grub.cfg")
        ("bootcfg-new" "new-bootcfg" "-"
         "/gnu/store/ffffffffffffffffffffffffffffffff-grub.cfg")))
    (phases . ,%phases)))

(define %checks 0)

(define (fail format-string . arguments)
  (format (current-error-port)
          "~a: FAIL: ~a~%"
          %program
          (apply format #f format-string arguments))
  (exit 1))

(define (check condition label)
  (set! %checks (+ %checks 1))
  (unless condition (fail "~a" label)))

(define (boundary-error? thunk)
  (catch sk:boundary-error-key
    (lambda () (thunk) #f)
    (lambda _ #t)))

(define (replace-association alist key value)
  (map (lambda (entry)
         (if (eq? (car entry) key) (cons key value) entry))
       alist))

(define (review? classification)
  (string=? (car classification) "REVIEW-REQUIRED"))

(define (test-sha256 text)
  (bytevector->base16-string
   (bytevector-hash
    (string->utf8 text)
    (hash-algorithm sha256))))

(define %journal-header
  (string-append
   "schema\tp5.2b-system-prune-journal/v1\n"
   "manifest\t" %sha "\n"
   "mode\tFIXTURE-ONLY\n"
   "transaction\t" %sha "\n"))

;; Test-only renderer for adversarial, internally hash-valid histories.
;; Production `sk:render-journal' intentionally refuses these histories.
(define (render-unchecked-chain history)
  (let loop ((remaining history)
             (sequence 1)
             (previous (test-sha256 %journal-header))
             (result %journal-header))
    (if (null? remaining)
        result
        (let* ((item (car remaining))
               (payload
                (string-join
                 (list (number->string sequence)
                       (car item)
                       (cadr item)
                       previous)
                 "\t"))
               (digest (test-sha256 payload))
               (row
                (string-append
                 "event\t" payload "\t" digest "\n")))
          (loop (cdr remaining)
                (+ sequence 1)
                digest
                (string-append result row))))))

(define (snapshot program base transaction-lock system-lock namespace roots
                  transaction-dir quarantine journal backup)
  (let ((history
         (case journal
           ((begin) '(("BEGIN" "-")))
           ((active)
            (take %forward
                  (+ 1
                     (list-index
                      (lambda (item)
                        (string=? (car item) "BACKUP-DONE"))
                      %forward))))
           ((terminal) %forward)
           (else '()))))
    `((protected? . #t)
      (foreign? . #f)
      (program-root . ,program)
      (transaction-base . ,base)
      (transaction-lock . ,transaction-lock)
      (system-lock . ,system-lock)
      (root-namespace . ,namespace)
      (durable-roots . ,roots)
      (transaction-dir . ,transaction-dir)
      (quarantine . ,quarantine)
      (journal . ,journal)
      (journal-history . ,history)
      (live-grub . ,(if (eq? journal 'terminal) 'new 'old))
      (live-bootcfg . ,(if (eq? journal 'terminal) 'new 'old))
      (grub-temporary . absent)
      (bootcfg-temporary . absent)
      (backup . ,backup))))

(define (legacy-snapshot transaction-dir quarantine journal backup)
  `((protected? . #t)
    (foreign? . #f)
    (program-root . absent)
    (roots . ())
    (transaction-dir . ,transaction-dir)
    (quarantine . ,quarantine)
    (journal-temp . ,journal)
    (backup . ,backup)))

;; Closed manifest and ordered-root model.
(check (equal? (sk:assert-boundary-manifest %manifest) %manifest)
       "closed manifest was not accepted")
(check (boundary-error?
        (lambda ()
          (sk:assert-boundary-manifest
           (append %manifest '((unknown . "row"))))))
       "unknown manifest key was accepted")
(check (boundary-error?
        (lambda ()
          (sk:assert-boundary-manifest
           (replace-association %manifest 'authorization "GRANTED"))))
       "authorization widening was accepted")
(check (boundary-error?
        (lambda ()
          (sk:assert-boundary-manifest
           (replace-association %manifest 'manifest-sha "short"))))
       "invalid manifest SHA256 was accepted")
(for-each
 (lambda (target label)
   (check
    (boundary-error?
     (lambda ()
       (sk:assert-boundary-manifest
        (replace-association
         %manifest 'program-root
         (list (car (cdr (assq 'program-root %manifest))) target)))))
    label))
 (list
  "/gnu/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-system-pruning-loaded.scm"
  "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system-pruning-loaded.scm/child"
  "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA-system-pruning-loaded.scm")
 '("non-Guix store hash alphabet was accepted"
   "nested path below a store item was accepted"
   "uppercase store hash character was accepted"))
(let* ((roots (sk:boundary-roots %manifest))
       (reordered (append (list (cadr roots) (car roots)) (drop roots 2))))
  (check
   (boundary-error?
    (lambda ()
      (sk:assert-boundary-manifest
       (replace-association %manifest 'roots reordered))))
   "reordered candidate roots were accepted"))
(let* ((roots (sk:boundary-roots %manifest))
       (duplicated
        (append (drop-right roots 1)
                (list (list "bootcfg-new" "old-bootcfg" "-"
                            (list-ref (last roots) 3))))))
  (check
   (boundary-error?
    (lambda ()
      (sk:assert-boundary-manifest
       (replace-association %manifest 'roots duplicated))))
   "duplicate ordered root name was accepted"))

;; Every prefix of every generated trace is legal, including both recovery
;; directions.  The semantic layer receives already shape/hash-validated rows.
(let ((traces (sk:legal-journal-traces %manifest)))
  (check (> (length traces) 4) "closed automaton did not generate branches")
  (check
   (sk:call-with-journal-trace-cache
    %manifest
    (lambda ()
      (let ((public-copy (sk:legal-journal-traces %manifest))
            (expected (sk:legal-journal-traces %manifest)))
        (set-car! (caar public-copy) "POISON")
        (and (not (equal? public-copy expected))
             (equal? expected (sk:legal-journal-traces %manifest))
             (equal?
              (sk:assert-legal-journal-history
               %manifest '(("BEGIN" "-")))
              '(("BEGIN" "-")))))))
   "public trace mutation poisoned the private dynamic automaton")
  (check
   (not
    (any
     (lambda (trace)
       (any (lambda (item)
              (member (car item)
                      '("ROOT-CREATE-INTENT" "ROOT-CREATE-DONE"
                        "ROOT-ENSURE-INTENT" "ROOT-ENSURE-DONE")))
            trace))
     traces))
   "integrated automaton retained legacy root-create/ensure journal rows")
  (for-each
   (lambda (trace)
     (for-each
      (lambda (length)
        (check
         (equal? (sk:assert-legal-journal-history
                  %manifest (take trace length))
                 (take trace length))
         "a generated legal journal prefix was rejected"))
      (iota (length trace) 1)))
   traces))

(define %forward (car (sk:legal-journal-traces %manifest)))
(define %complete-index
  (list-index (lambda (item) (string=? (car item) "COMPLETE")) %forward))
(define %committed-index
  (list-index (lambda (item) (string=? (car item) "COMMITTED")) %forward))
(define %committed-prefix (take %forward (+ %committed-index 1)))
(define %forward-cleanup (drop %forward (+ %committed-index 1)))

;; Canonical D4 journal codec: exact header, contiguous sequence, predecessor
;; and digest chain, then the closed semantic automaton.
(define %initial-journal
  (sk:render-journal %manifest '(("BEGIN" "-"))))
(check (string-prefix? %journal-header %initial-journal)
       "canonical journal header bytes differ")
(check (equal? (sk:parse-journal %manifest %initial-journal)
               '(("BEGIN" "-")))
       "canonical BEGIN journal did not round-trip")
(let ((prefix (take %forward 8)))
  (check (equal? (sk:parse-journal
                  %manifest (sk:render-journal %manifest prefix))
                 prefix)
         "legal active journal did not round-trip"))
(check
 (string=?
  (sk:append-journal-event
   %manifest %initial-journal '("BACKUP-DONE" "-"))
  (sk:render-journal %manifest (take %forward 2)))
 "legal journal append was not canonical")
(check
 (boundary-error?
  (lambda ()
    (sk:append-journal-event
     %manifest %initial-journal '("COMMITTED" "-"))))
 "illegal journal append was accepted")
(check
 (boundary-error? (lambda () (sk:parse-journal %manifest %journal-header)))
 "durable journal with empty history was accepted")
(check
 (boundary-error?
  (lambda ()
    (sk:parse-journal
     %manifest
     (string-append (substring %initial-journal
                               0 (- (string-length %initial-journal) 2))
                    "z\n"))))
 "journal digest mutation was accepted")
(for-each
 (lambda (history label)
   (check
    (boundary-error?
     (lambda ()
       (sk:parse-journal %manifest (render-unchecked-chain history))))
    label))
 (list
  '(("BEGIN" "-") ("BEGIN" "-"))
  (append (take %forward 2) (drop %forward 3))
  (append (take %forward 3)
          (list (list-ref %forward 4) (list-ref %forward 3)))
  (append %forward '(("BACKUP-DONE" "-"))))
 '("hash-valid duplicate event history was accepted"
   "hash-valid skipped event history was accepted"
   "hash-valid reordered event history was accepted"
   "hash-valid terminal suffix was accepted"))

(define (history-through trace name)
  (let ((index
         (list-index (lambda (item) (string=? (car item) name)) trace)))
    (unless index (fail "journal trace lacks required event: ~a" name))
    (take trace (+ index 1))))

(define (with-values alist replacements)
  (fold (lambda (replacement result)
          (replace-association result (car replacement) (cdr replacement)))
        alist
        replacements))

(define (illegal history label)
  (check (boundary-error?
          (lambda ()
            (sk:assert-legal-journal-history %manifest history)))
         label))

(illegal (append (take %forward (+ %committed-index 1))
                 (list '("COMMITTED" "-")))
         "duplicate COMMITTED was accepted")
(illegal (append (take %forward (+ %complete-index 1))
                 (list '("COMPLETE" "-")))
         "duplicate COMPLETE was accepted")
(let* ((rollback
        (find (lambda (trace)
                (any (lambda (item) (string=? (car item) "ROLLED-BACK"))
                     trace))
              (sk:legal-journal-traces %manifest)))
       (terminal-index
        (list-index (lambda (item) (string=? (car item) "ROLLED-BACK"))
                    rollback)))
  (illegal (append (take rollback (+ terminal-index 1))
                   (list '("ROLLED-BACK" "-")))
           "duplicate ROLLED-BACK was accepted")
  (illegal (append (take rollback (+ terminal-index 1))
                   (list '("GRUB-REPLACE-INTENT" "-")))
           "forward suffix after ROLLED-BACK was accepted")
  (illegal (append (take rollback (+ terminal-index 1))
                   (list '("FORWARD-RECOVERY-BEGIN" "-")))
           "forward-recovery marker after ROLLED-BACK was accepted"))
(illegal (append (take %forward 2) (drop %forward 3))
         "skipped journal event was accepted")
(illegal (append (take %forward 3)
                 (list (list-ref %forward 4) (list-ref %forward 3)))
         "reordered journal events were accepted")
(illegal (append (take %forward (+ %committed-index 1))
                 (list '("ROLLBACK-BEGIN" "-")))
         "rollback after commit was accepted")
(illegal (append (take %forward (+ %complete-index 1))
                 (list '("ROOT-REMOVE-INTENT" "candidate-g1")))
         "suffix after COMPLETE was accepted")
(let ((link-index
       (list-index
        (lambda (item) (equal? item '("LINK-EXCLUDE-INTENT" "1")))
        %forward)))
  (illegal
   (append (take %forward link-index)
           (list '("LINK-EXCLUDE-INTENT" "2")))
   "wrong ordered generation subject was accepted")
  (illegal
   (append (take %forward (+ link-index 1))
           (list '("LINK-EXCLUDE-DONE" "2")))
   "intent/done subject mismatch was accepted"))
(illegal (append (take %forward (+ %committed-index 1))
                 (list '("FORWARD-RECOVERY-BEGIN" "-")
                       '("FORWARD-RECOVERY-BEGIN" "-")))
         "duplicate forward recovery marker was accepted")
(for-each
 (lambda (length)
   (let ((expected
          (append %committed-prefix
                  (take %forward-cleanup length)
                  '(("FORWARD-RECOVERY-BEGIN" "-"))
                  (drop %forward-cleanup length))))
     (check
      (member expected (sk:legal-journal-traces %manifest))
      "post-COMMITTED cleanup prefix rejected its one recovery marker")))
 (iota (length %forward-cleanup)))
(illegal
 (append %committed-prefix
         (take %forward-cleanup 1)
         '(("FORWARD-RECOVERY-BEGIN" "-")
           ("FORWARD-RECOVERY-BEGIN" "-"))
         (drop %forward-cleanup 1))
 "duplicate cleanup recovery marker was accepted")
(illegal
 (append %committed-prefix
         (take %forward-cleanup 1)
         '(("FORWARD-RECOVERY-BEGIN" "-"))
         (take %forward-cleanup 1)
         (drop %forward-cleanup 1))
 "cleanup event completed before recovery marker was repeated afterward")
(illegal
 (append %forward '(("FORWARD-RECOVERY-BEGIN" "-")))
 "recovery marker after COMPLETE was accepted")
(illegal
 (append (take %committed-prefix %committed-index)
         '(("FORWARD-RECOVERY-BEGIN" "-")))
 "recovery marker before COMMITTED was accepted")
(check
 (boundary-error?
  (lambda ()
    (sk:assert-legal-journal-successor
     %manifest '(("BEGIN" "-")) '("COMMITTED" "-"))))
 "illegal proposed successor was accepted")
(check
 (equal?
  (sk:assert-legal-journal-successor
   %manifest '(("BEGIN" "-")) '("BACKUP-DONE" "-"))
 '("BACKUP-DONE" "-"))
 "legal proposed successor was rejected")
(sk:call-with-journal-trace-cache
 %manifest
 (lambda ()
   (let* ((history '(("BEGIN" "-")))
          (successors (sk:journal-legal-successors %manifest history))
          (expected (sk:journal-legal-successors %manifest history)))
     (set-car! (car successors) "POISON")
     (check
      (equal? expected (sk:journal-legal-successors %manifest history))
      "public successor mutation poisoned the private dynamic automaton")
     (check
      (boundary-error?
       (lambda ()
         (sk:assert-legal-journal-successor
          %manifest history (car successors))))
      "mutated public successor was accepted"))))
(check
 (equal? (sk:journal-head %manifest '(("BEGIN" "-")))
         '("BEGIN" "-"))
 "validated journal head was not returned")
(check
 (eq? (sk:journal-history-status %manifest '(("BEGIN" "-"))) 'begin)
 "BEGIN-only journal was not classified as begin")
(check
 (eq? (sk:journal-history-status
       %manifest (take %forward (+ %committed-index 1)))
      'active)
 "committed nonterminal journal was not classified as active")
(check
 (eq? (sk:journal-history-status %manifest %forward) 'terminal)
 "COMPLETE journal was not classified as terminal")

(let* ((rollback
        (find (lambda (trace)
                (any (lambda (item)
                       (string=? (car item) "ROLLBACK-BEGIN"))
                     trace))
              (sk:legal-journal-traces %manifest)))
       (begin-index
        (list-index (lambda (item)
                      (string=? (car item) "ROLLBACK-BEGIN"))
                    rollback)))
  (illegal
   (append (take rollback (+ begin-index 1))
           (list '("GRUB-REPLACE-INTENT" "-")))
   "forward mutation resumed after ROLLBACK-BEGIN"))
(let* ((traces (sk:legal-journal-traces %manifest))
       (expected-link-restores
        (append-map
         (lambda (root)
           (let ((subject (list-ref root 2)))
             (list (list "LINK-RESTORE-INTENT" subject)
                   (list "LINK-RESTORE-DONE" subject))))
         (drop-right (sk:boundary-roots %manifest) 2)))
       (early
        (find
         (lambda (trace)
           (and (member '("ROLLBACK-BEGIN" "-") trace)
                (not (member '("GRUB-REPLACE-DONE" "-") trace))))
         traces))
       (after-grub
        (find
         (lambda (trace)
           (and (member '("ROLLBACK-BEGIN" "-") trace)
                (member '("GRUB-REPLACE-DONE" "-") trace)
                (not (member '("BOOTCFG-PROMOTE-DONE" "-") trace))))
         traces))
       (after-bootcfg
        (find
         (lambda (trace)
           (and (member '("ROLLBACK-BEGIN" "-") trace)
                (member '("BOOTCFG-PROMOTE-DONE" "-") trace)))
         traces)))
  (check
   (and early
        (not (member '("GRUB-RESTORE-INTENT" "-") early))
        (not (member '("BOOTCFG-RESTORE-INTENT" "-") early)))
   "early rollback included a restore for an uncompleted forward phase")
  (check
   (and after-grub
        (member '("GRUB-RESTORE-INTENT" "-") after-grub)
        (not (member '("BOOTCFG-RESTORE-INTENT" "-") after-grub)))
   "post-GRUB rollback did not contain only the required GRUB restore")
  (check
   (and after-bootcfg
        (member '("GRUB-RESTORE-INTENT" "-") after-bootcfg)
        (member '("BOOTCFG-RESTORE-INTENT" "-") after-bootcfg))
   "post-bootcfg rollback omitted a required restore")
  (for-each
   (lambda (trace)
     (check
      (equal?
       (filter (lambda (item)
                 (member (car item)
                         '("LINK-RESTORE-INTENT" "LINK-RESTORE-DONE")))
               trace)
       expected-link-restores)
      "rollback link-restore rows are not exact and deterministic"))
   (filter (lambda (trace) (member '("ROLLBACK-BEGIN" "-") trace)) traces))
  (illegal
   (let ((rollback-index
          (list-index (lambda (item)
                        (equal? item '("ROLLBACK-BEGIN" "-")))
                      early)))
     (append (take early (+ rollback-index 1))
             '(("GRUB-RESTORE-INTENT" "-"))))
   "early rollback accepted a GRUB restore without completed replacement")
  (illegal
   (let ((restore-index
          (list-index (lambda (item)
                        (equal? item '("GRUB-RESTORE-DONE" "-")))
                      after-grub)))
     (append (take after-grub (+ restore-index 1))
             '(("BOOTCFG-RESTORE-INTENT" "-"))))
   "rollback accepted bootcfg restore without completed promotion"))
(for-each
 (lambda (trace)
   (check
    (<= (count (lambda (item)
                 (string=? (car item) "ROLLBACK-BEGIN"))
               trace)
        1)
    "legal trace contains a duplicate rollback marker")
   (check
    (<= (count (lambda (item)
                 (string=? (car item) "FORWARD-RECOVERY-BEGIN"))
               trace)
        1)
    "legal trace contains a duplicate forward-recovery marker"))
 (sk:legal-journal-traces %manifest))

;; Construction helpers validate both exact bytes and closed metadata.
(define %canonical-bytes "BEGIN\n")
(define (metadata size)
  `((kind . regular)
    (owner . 0)
    (mode . 384)
    (nlink . 1)
    (size . ,size)))
(for-each
 (lambda (length)
   (let ((prefix (substring %canonical-bytes 0 length)))
     (check
      (string=?
       (sk:assert-construction-prefix
        "journal" prefix %canonical-bytes (metadata length) 0 384)
       prefix)
      "canonical construction prefix was rejected")))
 '(0 1 5 6))
(check
 (boundary-error?
  (lambda ()
    (sk:assert-construction-prefix
     "journal" "BX" %canonical-bytes (metadata 2) 0 384)))
 "non-prefix construction bytes were accepted")
(check
 (boundary-error?
  (lambda ()
    (sk:assert-construction-prefix
     "journal" "BEGIN\nX" %canonical-bytes (metadata 7) 0 384)))
 "oversized construction bytes were accepted")
(check
 (boundary-error?
  (lambda ()
    (sk:assert-construction-prefix
     "journal" "B" %canonical-bytes
     (replace-association (metadata 1) 'mode 420)
     0 384)))
 "wrong construction mode was accepted")
(check
 (boundary-error?
  (lambda ()
    (sk:assert-construction-prefix
     "journal" "B" %canonical-bytes
     (replace-association (metadata 1) 'nlink 2)
     0 384)))
 "shared construction inode was accepted")
(check
 (string=?
  (sk:assert-construction-prefix
   "UTF-8 journal" "é" "éX" (metadata 2) 0 384)
  "é")
 "multibyte UTF-8 byte prefix was rejected")
(check
 (boundary-error?
  (lambda ()
    (sk:assert-construction-prefix
     "UTF-8 journal" "é" "éX" (metadata 1) 0 384)))
 "multibyte UTF-8 character count was accepted as byte size")

;; Program-root-first construction classifier.
(define %root-names (map cadr (sk:boundary-roots %manifest)))

(define (classification-next value)
  (cadr value))

(check
 (string=? (car (sk:classify-bootstrap
                 %manifest
                 (snapshot 'absent 'absent 'absent 'absent 'absent '()
                           'absent 'absent 'absent 'absent)))
           "INITIAL-ELIGIBLE")
 "empty bootstrap state was not initial-eligible")
(check
 (string=? (classification-next
            (sk:classify-bootstrap
             %manifest
             (snapshot 'exact 'absent 'absent 'absent 'absent '()
                       'absent 'absent 'absent 'absent)))
           "transaction-base")
 "program-root-only prefix was not recognized")
(check
 (string=? (classification-next
            (sk:classify-bootstrap
             %manifest
             (snapshot 'exact 'exact 'exact 'absent 'absent '()
                       'absent 'absent 'absent 'absent)))
           "system-lock")
 "transaction-lock prefix was not recognized")
(for-each
 (lambda (count)
   (let ((classification
          (sk:classify-bootstrap
           %manifest
           (snapshot 'exact 'exact 'exact 'exact 'exact
                     (take %root-names count)
                     'absent 'absent 'absent 'absent))))
     (if (< count (length %root-names))
         (check
          (string=?
           (classification-next classification)
           (string-append "durable-root:" (list-ref %root-names count)))
          "ordered durable-root prefix chose the wrong successor")
         (check
          (string=? (classification-next classification)
                    "transaction-directory")
          "complete durable-root set did not advance to transaction dir"))))
 (iota (+ (length %root-names) 1)))
(check
 (string=? (classification-next
            (sk:classify-bootstrap
             %manifest
             (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
                       'exact 'exact 'initial-temp-prefix 'absent)))
           "reconcile-initial-journal")
 "initial journal prefix was not recognized")
(check
 (string=? (classification-next
            (sk:classify-bootstrap
             %manifest
             (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
                       'exact 'exact 'begin 'partial-prefix)))
           "replace-partial-backup")
 "partial backup prefix was not recognized")
(check
 (string=? (classification-next
            (sk:classify-bootstrap
             %manifest
             (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
                       'exact 'exact 'begin 'exact)))
           "append-BACKUP-DONE")
 "complete unjournaled backup was not recognized")
(check
 (string=? (car
            (sk:classify-bootstrap
             %manifest
             (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
                       'exact 'exact 'active 'done)))
           "JOURNAL-RECOVERY")
 "active journal state was not routed to journal recovery")
(define %rollback-after-bootcfg
  (find
   (lambda (trace)
     (and (any (lambda (item)
                 (string=? (car item) "BOOTCFG-PROMOTE-DONE"))
               trace)
          (any (lambda (item)
                 (string=? (car item) "BOOTCFG-RESTORE-INTENT"))
               trace)))
   (sk:legal-journal-traces %manifest)))

(for-each
 (lambda (case)
   (check
    (string=? (car (sk:classify-bootstrap %manifest case))
              "JOURNAL-RECOVERY")
    "journal-bound known temporary was not routed to recovery"))
 (list
  (with-values
   (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
             'exact 'exact 'active 'done)
   `((journal-history
      . ,(history-through %forward "GRUB-REPLACE-INTENT"))
     (live-grub . old)
     (live-bootcfg . old)
     (grub-temporary . exact-new)))
  (with-values
   (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
             'exact 'exact 'active 'done)
   `((journal-history
      . ,(history-through %forward "BOOTCFG-PROMOTE-INTENT"))
     (live-grub . new)
     (live-bootcfg . old)
     (bootcfg-temporary . exact-new)))
  (with-values
   (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
             'exact 'exact 'active 'done)
   `((journal-history
      . ,(history-through %rollback-after-bootcfg "GRUB-RESTORE-INTENT"))
     (live-grub . new)
     (live-bootcfg . new)
     (grub-temporary . exact-old)))
  (with-values
   (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
             'exact 'exact 'active 'done)
   `((journal-history
      . ,(history-through %rollback-after-bootcfg "BOOTCFG-RESTORE-INTENT"))
     (live-grub . old)
     (live-bootcfg . new)
     (bootcfg-temporary . exact-old)))))
(for-each
 (lambda (case)
   (check (review? (sk:classify-bootstrap %manifest case))
          "temporary with mismatched journal/live predecessor was accepted"))
 (list
  ;; Exact bytes alone are insufficient: the journal head is too early.
  (replace-association
   (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
             'exact 'exact 'active 'done)
   'grub-temporary 'exact-new)
  ;; The correct head still requires the exact predecessor live state.
  (with-values
   (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
             'exact 'exact 'active 'done)
   `((journal-history
      . ,(history-through %forward "GRUB-REPLACE-INTENT"))
     (live-grub . new)
     (live-bootcfg . old)
     (grub-temporary . exact-new)))
  ;; Direction is bound too: old bytes cannot be a forward replacement temp.
  (with-values
   (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
             'exact 'exact 'active 'done)
   `((journal-history
      . ,(history-through %forward "GRUB-REPLACE-INTENT"))
     (live-grub . old)
     (live-bootcfg . old)
     (grub-temporary . exact-old)))
  ;; A symbolic active state cannot hide an illegal event history.
  (replace-association
   (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
             'exact 'exact 'active 'done)
   'journal-history
   '(("BEGIN" "-") ("COMMITTED" "-")))))
(check
 (review?
  (sk:classify-bootstrap
   %manifest
   (replace-association
    (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
              'exact 'exact 'begin 'exact)
    'grub-temporary 'exact-new)))
 "GRUB temporary at BEGIN was accepted")
(check
 (review?
  (sk:classify-bootstrap
   %manifest
   (replace-association
    (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
              'exact 'exact 'terminal 'done)
    'bootcfg-temporary 'exact-old)))
 "terminal journal with a temporary was accepted")
(check
 (review?
  (sk:classify-bootstrap
   %manifest
   (replace-association
    (replace-association
     (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
               'exact 'exact 'active 'done)
     'grub-temporary 'exact-new)
    'bootcfg-temporary 'exact-old)))
 "multiple known transaction temporaries were accepted")
(for-each
 (lambda (key)
   (check
    (review?
     (sk:classify-bootstrap
      %manifest
      (replace-association
       (snapshot 'exact 'exact 'exact 'exact 'exact
                 (take %root-names 1)
                 'absent 'absent 'absent 'absent)
       key 'exact-new)))
    "incomplete durable-root prefix accepted a transaction temporary"))
 '(grub-temporary bootcfg-temporary))

(define %bootstrap-review-cases
  (list
   (snapshot 'absent 'exact 'absent 'absent 'absent '()
             'absent 'absent 'absent 'absent)
   (snapshot 'exact 'absent 'exact 'absent 'absent '()
             'absent 'absent 'absent 'absent)
   (snapshot 'exact 'exact 'exact 'exact 'exact
             '("candidate-g2")
             'absent 'absent 'absent 'absent)
   (snapshot 'exact 'exact 'exact 'exact 'exact
             (take %root-names 1)
             'exact 'absent 'absent 'absent)
   (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
             'exact 'exact 'initial-temp-prefix 'partial-prefix)
   (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
             'exact 'exact 'terminal 'exact)))
(for-each
 (lambda (case)
   (check (review? (sk:classify-bootstrap %manifest case))
          "ambiguous bootstrap state was accepted"))
 %bootstrap-review-cases)
(check
 (review?
  (sk:classify-bootstrap
   %manifest
   (replace-association
    (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
              'absent 'absent 'absent 'absent)
    'protected? #f)))
 "protected bootstrap drift was accepted")
(check
 (review?
  (sk:classify-bootstrap
   %manifest
   (replace-association
    (snapshot 'exact 'exact 'exact 'exact 'exact %root-names
              'absent 'absent 'absent 'absent)
    'foreign? #t)))
 "foreign bootstrap state was accepted")

;; The legacy classifier is a distinct, explicitly rootless API.
(check
 (string=? (classification-next
            (sk:classify-legacy-gap
             (legacy-snapshot 'exact 'absent 'absent 'absent)))
           "remove-empty-transaction-directory")
 "legacy transaction-directory-only row was not recognized")
(check
 (string=? (classification-next
            (sk:classify-legacy-gap
             (legacy-snapshot 'exact 'exact 'absent 'absent)))
           "remove-empty-quarantine-and-directory")
 "legacy empty-quarantine row was not recognized")
(for-each
 (lambda (state)
   (check
    (string=? (classification-next
               (sk:classify-legacy-gap
                (legacy-snapshot 'exact 'exact state 'absent)))
              "reconcile-legacy-initial-journal")
    "legacy canonical journal temporary was not recognized"))
 '(prefix equal))
(check
 (review?
  (sk:classify-legacy-gap
   (replace-association
    (legacy-snapshot 'exact 'exact 'prefix 'absent)
    'roots '("candidate-g1"))))
 "legacy rootless classifier accepted a recovery root")
(check
 (review?
  (sk:classify-legacy-gap
   (legacy-snapshot 'exact 'exact 'foreign 'absent)))
 "legacy non-prefix journal bytes were accepted")

;; Central gate: each callback is mandatory, ordered, and can prevent THUNK.
(let ((calls '())
      (ran? #f))
  (define guards
    (map
     (lambda (key)
       (cons key
             (lambda (_manifest _phase _state)
               (set! calls (append calls (list key)))
               #t)))
     '(protected journal roots session quiescence)))
  (check
   (eq? (sk:call-with-pre-phase-gate
         %manifest "grub-replace" 'state guards
         (lambda () (set! ran? #t) 'ran))
        'ran)
   "accepting pre-phase gate did not run the phase")
  (check ran? "accepting pre-phase gate skipped the continuation")
  (check (equal? calls '(protected journal roots session quiescence))
         "pre-phase guards ran in the wrong order"))

(for-each
 (lambda (refused)
   (let ((ran? #f)
         (calls '()))
     (let ((guards
            (map
             (lambda (key)
               (cons key
                     (lambda (_manifest _phase _state)
                       (set! calls (append calls (list key)))
                       (not (eq? key refused)))))
             '(protected journal roots session quiescence))))
       (check
        (boundary-error?
         (lambda ()
           (sk:call-with-pre-phase-gate
            %manifest "grub-replace" 'state guards
            (lambda () (set! ran? #t)))))
        "refusing pre-phase guard did not fail")
       (check (not ran?) "phase ran after a guard refusal")
       (check (equal? (last calls) refused)
              "guards continued after a refusal"))))
 '(protected journal roots session quiescence))
(check
 (boundary-error?
  (lambda ()
    (sk:call-with-pre-phase-gate
     %manifest "unknown-phase" 'state
     (map (lambda (key) (cons key (lambda _ #t)))
          '(protected journal roots session quiescence))
     (lambda () #t))))
 "unregistered phase was accepted")

;; Every prefix of the exact cleanup plan is restart-recognizable.  Program
;; root removal must remain the last operation after the durable terminal.
(for-each
 (lambda (terminal)
   (let ((plan (sk:terminal-cleanup-plan %manifest terminal)))
     (for-each
      (lambda (length)
        (check
         (equal? (sk:assert-terminal-cleanup-prefix
                  %manifest terminal (take plan length))
                 (take plan length))
         "legal terminal cleanup prefix was rejected"))
      (iota (+ (length plan) 1)))
     (check
      (boundary-error?
       (lambda ()
         (sk:assert-terminal-cleanup-prefix
          %manifest terminal
          (list (last plan)))))
      "program root removal was accepted before terminal cleanup")
     (check
      (equal? (car (last plan)) "remove-program-root")
      "program root is not last in terminal cleanup plan")
     (check
      (equal? (list-ref plan (- (length plan) 2))
              (list "append-terminal" terminal))
      "terminal event does not immediately precede program-root cleanup")))
 '("COMPLETE" "ROLLED-BACK"))

(format #t "~a: PASS~%" %program)
