;;; Pure tests for the D4c.1a live reconciliation classifier.

(use-modules (sk system-pruning-live-boundary)
             (sk system-pruning-live-contract-fixture)
             (sk system-pruning-live-grant)
             (sk system-pruning-live-reconciliation)
             (srfi srfi-1))

(define %program "guix-system-pruning-live-reconciliation-check")
(define %checks 0)

(define (check condition label)
  (set! %checks (+ %checks 1))
  (unless condition (error %program label)))

(define (expect-error thunk label)
  (set! %checks (+ %checks 1))
  (unless
      (catch sk:live-reconciliation-error-key
        (lambda () (thunk) #f)
        (lambda _ #t))
    (error %program (string-append "expected failure: " label))))

(define (expect-grant-error thunk label)
  (set! %checks (+ %checks 1))
  (unless
      (catch sk:d5-live-grant-error-key
        (lambda () (thunk) #f)
        (lambda _ #t))
    (error %program (string-append "expected grant failure: " label))))

(define (classification-name classification)
  (car classification))

(define (classification-next classification)
  (cadr classification))

(define (review? classification)
  (string=? (classification-name classification) "REVIEW-REQUIRED"))

(define (history-through trace event-name)
  (let loop ((remaining trace) (result '()))
    (let* ((item (car remaining))
           (next (append result (list item))))
      (if (string=? (car item) event-name)
          next
          (loop (cdr remaining) next)))))

(define %absent
  (make-live-observation
   'absent 'absent 'absent 'absent 'absent 'absent '()
   'absent 'absent 'absent 'absent))

(define %initial
  (sk:classify-live-reconciliation %live-boundary %absent))

(check (string=? (classification-name %initial) "INITIAL-ELIGIBLE")
       "exact absent prestate was not initial-eligible")
(check (eq? (sk:live-reconciliation-required-grant %initial) 'execution)
       "initial state did not require the execution grant")
(check (string=? (sk:live-reconciliation-direction %initial '()) "INITIAL")
       "initial direction drifted")
(check (string=? (sk:live-reconciliation-next-phase %initial)
                 "program-temporary-root")
       "initial first phase drifted")

(define %bootstrap-cases
  (list
   (cons
    (make-live-observation
     'exact 'absent 'absent 'absent 'absent 'absent '()
     'absent 'absent 'absent 'absent)
    "transaction-base")
   (cons
    (make-live-observation
     'exact 'exact 'absent 'absent 'absent 'absent '()
     'absent 'absent 'absent 'absent)
    "transaction-lock")
   (cons
    (make-live-observation
     'exact 'exact 'exact 'absent 'absent 'absent '()
     'absent 'absent 'absent 'absent)
    "system-lock")
   (cons
    (make-live-observation
     'exact 'exact 'exact 'exact 'absent 'absent '()
     'absent 'absent 'absent 'absent)
    "recovery-root-base")
   (cons
    (make-live-observation
     'exact 'exact 'exact 'exact 'exact 'absent '()
     'absent 'absent 'absent 'absent)
    "root-namespace")
   (cons
    (make-live-observation
     'exact 'exact 'exact 'exact 'exact 'exact '()
     'absent 'absent 'absent 'absent)
    "durable-root:candidate-g1")
   (cons
    (make-live-observation
     'exact 'exact 'exact 'exact 'exact 'exact '("candidate-g1")
     'absent 'absent 'absent 'absent)
    "durable-root:old-bootcfg")
   (cons
    (make-live-observation
     'exact 'exact 'exact 'exact 'exact 'exact
     '("candidate-g1" "old-bootcfg")
     'absent 'absent 'absent 'absent)
    "durable-root:new-bootcfg")
   (cons
    (make-live-observation
     'exact 'exact 'exact 'exact 'exact 'exact %live-root-names
     'absent 'absent 'absent 'absent)
    "transaction-directory")
   (cons
    (make-live-observation
     'exact 'exact 'exact 'exact 'exact 'exact %live-root-names
     'exact 'absent 'absent 'absent)
    "quarantine")
   (cons
    (make-live-observation
     'exact 'exact 'exact 'exact 'exact 'exact %live-root-names
     'exact 'exact 'absent 'absent)
    "initial-journal")))

(for-each
 (lambda (case)
   (let ((classification
          (sk:classify-live-reconciliation %live-boundary (car case))))
     (check (string=? (classification-name classification) "RESUME")
            "exact bootstrap prefix was not resumable")
     (check (string=? (classification-next classification) (cdr case))
            "bootstrap prefix selected the wrong next phase")
     (check (eq? (sk:live-reconciliation-required-grant classification)
                 'recovery)
            "bootstrap continuation did not require recovery grant")
     (check (string=?
             (sk:live-reconciliation-direction classification '())
             "BOOTSTRAP")
            "bootstrap continuation direction drifted")
     (check (string=?
             (sk:live-reconciliation-next-phase classification)
             (cdr case))
            "bootstrap next-phase helper drifted")))
 %bootstrap-cases)

(define (skip-required-prefix observation next-phase)
  (cond
   ((string=? next-phase "transaction-base")
    (replace-live-observation observation 'transaction-lock 'exact))
   ((string=? next-phase "transaction-lock")
    (replace-live-observation observation 'system-lock 'exact))
   ((string=? next-phase "system-lock")
    (replace-live-observation observation 'recovery-root-base 'exact))
   ((string=? next-phase "recovery-root-base")
    (replace-live-observation observation 'root-namespace 'exact))
   ((string=? next-phase "root-namespace")
    (replace-live-observation
     observation 'durable-roots '("candidate-g1")))
   ((string=? next-phase "durable-root:candidate-g1")
    (replace-live-observation
     observation 'durable-roots '("old-bootcfg")))
   ((string=? next-phase "durable-root:old-bootcfg")
    (replace-live-observation
     observation 'durable-roots '("candidate-g1" "new-bootcfg")))
   ((string=? next-phase "durable-root:new-bootcfg")
    (replace-live-observation observation 'transaction-dir 'exact))
   ((string=? next-phase "transaction-directory")
    (replace-live-observation
     (replace-live-observation observation 'quarantine 'exact)
     'quarantine-entries 'empty))
   ((string=? next-phase "quarantine")
    (replace-live-observation observation 'journal 'initial-temp-equal))
   ((string=? next-phase "initial-journal")
    (replace-live-observation observation 'backup 'exact))
   (else (error %program "unmapped bootstrap test phase" next-phase))))

(for-each
 (lambda (case)
   (let ((classification
          (sk:classify-live-reconciliation
           %live-boundary
           (skip-required-prefix (car case) (cdr case)))))
     (check (review? classification)
            "skipped bootstrap prefix was not review-required")
     (check (eq? (sk:live-reconciliation-required-grant classification)
                 'none)
            "skipped bootstrap prefix requested a grant")))
 %bootstrap-cases)

(define %resume-observation (car (car %bootstrap-cases)))
(define %resume-classification
  (sk:classify-live-reconciliation %live-boundary %resume-observation))
(define %resume-binding
  (sk:live-reconciliation-grant-binding
   %live-boundary %resume-classification %resume-observation))

(define %resume-observation-text
  (string-append
   "schema\tp5.2b-system-prune-live-reconciliation-observation/v1\n"
   "protected?\tTRUE\n"
   "foreign?\tFALSE\n"
   "selected-links\tprestate\n"
   "program-root\texact\n"
   "transaction-base\tabsent\n"
   "transaction-lock\tabsent\n"
   "system-lock\tabsent\n"
   "recovery-root-base\tabsent\n"
   "root-namespace\tabsent\n"
   "durable-roots\t-\n"
   "transaction-dir\tabsent\n"
   "quarantine\tabsent\n"
   "quarantine-entries\tabsent\n"
   "journal\tabsent\n"
   "journal-history\t-\n"
   "live-grub\told\n"
   "live-bootcfg\told\n"
   "grub-temporary\tabsent\n"
   "bootcfg-temporary\tabsent\n"
   "backup\tabsent\n"))

(check (string=?
        (sk:render-live-reconciliation-observation
         %live-boundary %resume-observation)
        %resume-observation-text)
       "canonical observation bytes drifted")
(check (string=?
        (sk:live-reconciliation-observation-sha256
         %live-boundary %resume-observation)
        "6644b66d4655c975bf544311519463eb579ea40aef97178785d7af1146513f2b")
       "canonical observation digest drifted")
(check (equal? (map car %resume-binding)
               '(observed-journal-head observed-state-sha256
                 direction next-phase))
       "bootstrap grant binding keys or order drifted")
(check (string=? (cdr (assq 'next-phase %resume-binding))
                 "transaction-base")
       "bootstrap grant binding selected the wrong phase")
(define (recovery-context binding)
  (let ((program (cdr (assq 'program %live-boundary))))
    (append
     `((source-checkpoint
        . ,(cdr (assq 'source-checkpoint %live-boundary)))
       (packet-sha256 . ,(cdr (assq 'packet-sha %live-boundary)))
       (manifest-sha256 . ,(cdr (assq 'manifest-sha %live-boundary)))
       (program-path . ,(list-ref program 0))
       (program-sha256 . ,(list-ref program 1))
       (program-size . ,(list-ref program 2))
       (boot-id . ,(cdr (assq 'boot-id %live-boundary)))
       (action . "live-recover")
       (attended-attestation-sha256
        . "1111111111111111111111111111111111111111111111111111111111111111"))
     binding)))

(define %resume-context (recovery-context %resume-binding))
(define %resume-token (sk:render-d5-recovery-grant %resume-context))
(check (pair? (sk:read-d5-recovery-capability
               #f %resume-token %resume-context))
       "classifier-derived bootstrap recovery grant did not round-trip")

(define %second-observation (car (list-ref %bootstrap-cases 1)))
(define %second-classification
  (sk:classify-live-reconciliation %live-boundary %second-observation))
(define %second-binding
  (sk:live-reconciliation-grant-binding
   %live-boundary %second-classification %second-observation))
(define %second-context (recovery-context %second-binding))

(check (not (string=? (cdr (assq 'observed-state-sha256 %resume-binding))
                           (cdr (assq 'observed-state-sha256
                                      %second-binding))))
       "distinct bootstrap prefixes share one observation digest")
(check (not (string=? (cdr (assq 'next-phase %resume-binding))
                           (cdr (assq 'next-phase %second-binding))))
       "distinct bootstrap prefixes share one next phase")
(expect-grant-error
 (lambda ()
   (sk:read-d5-recovery-capability #f %resume-token %second-context))
 "grant replayed against another accepted bootstrap prefix")
(let* ((stale-context
        (replace-live-observation
         %resume-context 'next-phase "transaction-lock"))
       (stale-token (sk:render-d5-recovery-grant stale-context)))
  (expect-grant-error
   (lambda ()
     (sk:read-d5-recovery-capability #f stale-token %resume-context))
   "stale bootstrap next phase matched the current prefix"))
(expect-error
 (lambda ()
   (sk:live-reconciliation-grant-binding
    %live-boundary %resume-classification %second-observation))
 "classification accepted a different bootstrap observation")
(expect-error
 (lambda ()
   (sk:live-reconciliation-grant-binding
    %live-boundary '("RESUME" "system-lock" ()) %resume-observation))
 "grant binding accepted a stale classification")
(expect-error
 (lambda ()
   (sk:live-reconciliation-grant-binding
    %live-boundary %initial %absent))
 "initial execution state produced a recovery binding")

(define %forward
  (find (lambda (trace)
          (and (any (lambda (event)
                      (string=? (car event) "COMMITTED"))
                    trace)
               (string=? (car (last trace)) "COMPLETE")))
        (sk:legal-live-journal-traces %live-boundary)))
(define %active-history (history-through %forward "BACKUP-DONE"))
(define %active-observation
  (replace-live-observation
   (make-live-observation
    'exact 'exact 'exact 'exact 'exact 'exact %live-root-names
    'exact 'exact 'active 'done)
   'journal-history %active-history))
(define %active
  (sk:classify-live-reconciliation %live-boundary %active-observation))

(check (review? %active)
       "active journal was granted before phase-state policy exists")
(check (eq? (sk:live-reconciliation-required-grant %active) 'none)
       "review-only active journal requested a grant")
(check (not (sk:live-reconciliation-next-phase %active))
       "review-only journal invented a next phase")

(define %terminal-observation
  (replace-live-observation
   (make-live-observation
    'exact 'exact 'exact 'exact 'exact 'exact %live-root-names
    'exact 'exact 'terminal 'done)
   'journal-history %forward))
(check (review?
        (sk:classify-live-reconciliation
         %live-boundary %terminal-observation))
       "unfrozen terminal cleanup policy was treated as executable")

(for-each
 (lambda (case)
   (check (review?
           (sk:classify-live-reconciliation %live-boundary case))
          "unsafe or skipped live state was not review-required"))
 (list
  (replace-live-observation %absent 'protected? #f)
  (replace-live-observation %absent 'foreign? #t)
  (replace-live-observation %absent 'journal-history '(("BEGIN" "-")))
  (replace-live-observation %absent 'live-grub 'new)
  (make-live-observation
   'exact 'exact 'exact 'exact 'exact 'exact %live-root-names
   'exact 'exact 'initial-temp-prefix 'absent)
  (replace-live-observation
   (car (list-ref %bootstrap-cases 5)) 'selected-links 'changed)
  (replace-live-observation
   (car (list-ref %bootstrap-cases 9)) 'quarantine-entries 'occupied)
  (make-live-observation
   'absent 'exact 'absent 'absent 'absent 'absent '()
   'absent 'absent 'absent 'absent)
  (make-live-observation
   'exact 'exact 'exact 'exact 'exact 'exact
   '("old-bootcfg" "candidate-g1")
   'absent 'absent 'absent 'absent)
  (replace-live-observation %active-observation
                            'grub-temporary 'exact-old)
  (replace-live-observation %active-observation
                            'journal-history
                            '(("BEGIN" "-") ("COMMITTED" "-")))))

(expect-error
 (lambda ()
   (sk:assert-live-reconciliation-observation
    %live-boundary (reverse %absent)))
 "reordered observation accepted")
(expect-error
 (lambda ()
   (sk:assert-live-reconciliation-observation
    %live-boundary
    (replace-live-observation %absent 'program-root 'maybe)))
 "unknown path state accepted")
(for-each
 (lambda (classification label)
   (expect-error
    (lambda ()
      (sk:live-reconciliation-required-grant classification))
    label))
 (list '("UNKNOWN" "-" ())
       '("INITIAL-ELIGIBLE" "transaction-base" ())
       '("RESUME" "not-a-phase" ())
       '("RESUME" "system-lock" ())
       '("RESUME" "transaction-base" ("bogus-lock"))
       '("REVIEW-REQUIRED" "reason" ("system-lock"))
       '("REVIEW-REQUIRED" "" ()))
 '("unknown classification accepted"
   "forged initial phase accepted"
   "unknown bootstrap phase accepted"
   "bootstrap phase with missing locks accepted"
   "bootstrap phase with foreign locks accepted"
   "review classification with locks accepted"
   "review classification with empty reason accepted"))

(format #t "~a: PASS (~a checks)~%" %program %checks)
