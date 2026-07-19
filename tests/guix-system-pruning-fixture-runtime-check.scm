;;; Executable and adversarial checks for the D4a in-memory fixture runtime.

(use-modules (gcrypt hash)
             (guix base16)
             (rnrs bytevectors)
             (sk system-pruning-boundary)
             (sk system-pruning-fixture-runtime)
             (sk system-pruning-phase-engine)
             (srfi srfi-1))

(define %program "guix-system-pruning-fixture-runtime-check")
(define %sha (make-string 64 #\a))
(define %program-target
  "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system-pruning-loaded.scm")
(define %roots
  '(("candidate" "candidate-g1" "1"
     "/gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-system")
    ("candidate" "candidate-g2" "2"
     "/gnu/store/cccccccccccccccccccccccccccccccc-system")
    ("bootcfg-old" "old-bootcfg" "-"
     "/gnu/store/dddddddddddddddddddddddddddddddd-grub.cfg")
    ("bootcfg-new" "new-bootcfg" "-"
     "/gnu/store/ffffffffffffffffffffffffffffffff-grub.cfg")))

(define %manifest
  `((schema . "p5.2b-system-prune-boundary/v1")
    (mode . "FIXTURE-ONLY")
    (authorization . "NOT-GRANTED")
    (manifest-sha . ,%sha)
    (program-root
     . (,(string-append
          "/var/guix/gcroots/p52b-system-prune-program-" %sha)
        ,%program-target))
    (roots . ,%roots)
    (phases . ,(sk:phase-engine-phase-registry %roots))))

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

(define (check-equal actual expected label)
  (check (equal? actual expected)
         (format #f "~a: expected ~s, got ~s" label expected actual)))

(define (fails? thunk)
  (catch #t
    (lambda () (thunk) #f)
    (lambda _ #t)))

(define (result-ref result key)
  (sk:fixture-runtime-result-ref result key))

(define (recorded? history event)
  (any (lambda (item) (string=? (car item) event)) history))

(define (normal-forward-trace)
  (or
   (find
    (lambda (trace)
      (and (recorded? trace "COMMITTED")
           (recorded? trace "COMPLETE")
           (not (recorded? trace "FORWARD-RECOVERY-BEGIN"))
           (not (recorded? trace "ROLLBACK-BEGIN"))))
    (sk:legal-journal-traces %manifest))
   (fail "normal forward trace is absent")))

(define %normal (normal-forward-trace))

(define (string-sha256 text)
  (bytevector->base16-string
   (bytevector-hash
    (string->utf8 text)
    (hash-algorithm sha256))))

(define (tsv-line fields)
  (string-append (string-join fields "\t") "\n"))

(define (journal-header)
  (list
   (list "schema" "p5.2b-system-prune-journal/v1")
   (list "manifest" %sha)
   (list "mode" "FIXTURE-ONLY")
   (list "transaction" %sha)))

(define (journal-payload sequence event subject predecessor)
  (string-join
   (list (number->string sequence) event subject predecessor)
   "\t"))

;; Test-only adversarial encoder.  Production code deliberately has no API
;; for rendering automaton-illegal history.
(define (unsafe-render-hash-valid-journal history)
  (let* ((header-text
          (string-concatenate (map tsv-line (journal-header))))
         (seed (string-sha256 header-text)))
    (let loop ((remaining history)
               (sequence 1)
               (predecessor seed)
               (rows '()))
      (if (null? remaining)
          (string-append
           header-text
           (string-concatenate (reverse rows)))
          (let* ((item (car remaining))
                 (payload
                  (journal-payload
                   sequence (car item) (cadr item) predecessor))
                 (digest (string-sha256 payload))
                 (row
                  (tsv-line
                   (list "event"
                         (number->string sequence)
                         (car item)
                         (cadr item)
                         predecessor
                         digest))))
            (loop (cdr remaining)
                  (+ sequence 1)
                  digest
                  (cons row rows)))))))

(define (parse-lines raw)
  (let ((lines (string-split raw #\newline)))
    (and (pair? lines)
         (string-null? (last lines))
         (map (lambda (line) (string-split line #\tab))
              (drop-right lines 1)))))

(define (physically-hash-valid? raw)
  (let ((records (parse-lines raw)))
    (and records
         (>= (length records) 5)
         (equal? (take records 4) (journal-header))
         (let loop ((remaining (drop records 4))
                    (sequence 1)
                    (predecessor
                     (string-sha256
                      (string-concatenate
                       (map tsv-line (journal-header))))))
           (if (null? remaining)
               #t
               (let ((row (car remaining)))
                 (and (= (length row) 6)
                      (string=? (car row) "event")
                      (string=?
                       (list-ref row 1)
                       (number->string sequence))
                      (string=? (list-ref row 4) predecessor)
                      (string=?
                       (list-ref row 5)
                       (string-sha256
                        (journal-payload
                         sequence
                         (list-ref row 2)
                         (list-ref row 3)
                         predecessor)))
                      (loop (cdr remaining)
                            (+ sequence 1)
                            (list-ref row 5)))))))))

(define (assert-exact-guards result label)
  (let ((timeline (result-ref result 'timeline))
        (effects 0))
    (let loop ((remaining timeline) (prior '()))
      (unless (null? remaining)
        (let ((item (car remaining)))
          (when (and (pair? item) (eq? (car item) 'effect))
            (set! effects (+ effects 1))
            (let* ((phase (cadr item))
                   (guards
                    (map
                     (lambda (key) `(guard ,phase ,key))
                     '(protected journal roots session quiescence))))
              (check (>= (length prior) 5)
                     (string-append label " effect lacks prior records"))
              (check-equal
               (take-right prior 5)
               guards
               (string-append label " exact five guards"))))
          (loop (cdr remaining) (append prior (list item))))))
    (check (= effects (result-ref result 'effect-count))
           (string-append label " timeline effect count"))
    (check (= (result-ref result 'guard-count) (* 5 effects))
           (string-append label " guard cardinality"))
    (check
     (every
      (lambda (phase)
        (member phase (result-ref result 'declared-phases)))
      (result-ref result 'executed-phases))
     (string-append label " executed phases are declared"))))

;; Verification constructs and validates the closed adapter without opening a
;; root session, calling the engine, or consuming the runtime.
(define verified-runtime (sk:make-fixture-runtime %manifest))
(define verification (sk:verify-fixture-runtime verified-runtime))
(check-equal (result-ref verification 'result) "VERIFIED"
             "verification result")
(check-equal (result-ref verification 'timeline) '()
             "verification timeline")
(check-equal (result-ref verification 'opened) 0
             "verification session count")
(check-equal (result-ref verification 'effect-count) 0
             "verification effect count")
(check-equal (sk:fixture-runtime-timeline verified-runtime) '()
             "verification runtime audit")

;; The same verified runtime then invokes the actual forward phase engine.
(define forward (sk:run-fixture-runtime!
                 verified-runtime "fixture-apply"))
(check-equal (result-ref forward 'result) "COMPLETE"
             "forward result")
(check-equal (result-ref forward 'terminal) "COMPLETE"
             "forward terminal")
(check-equal (result-ref forward 'history) %normal
             "forward exact automaton trace")
(check (= (result-ref forward 'opened) 1)
       "forward one session open")
(check (= (result-ref forward 'closed) 1)
       "forward one session close")
(check (= (result-ref forward 'lock-scopes) 1)
       "forward one lock scope")
(check (member "effect:grub-replace"
               (result-ref forward 'executed-phases))
       "forward did not invoke the GRUB engine phase")
(check (member "append-terminal:COMPLETE"
               (result-ref forward 'executed-phases))
       "forward did not invoke terminal cleanup")
(check (member "remove-root:program-root"
               (result-ref forward 'executed-phases))
       "forward did not remove the program root last")
(check-equal
 (sk:fixture-runtime-timeline verified-runtime)
 (result-ref forward 'timeline)
 "successful runtime audit timeline")
(assert-exact-guards forward "forward")

;; Recovery starts from the canonical hash-chained precommit prefix and must
;; select the automaton's rollback branch through the same engine.
(define recovery-runtime (sk:make-fixture-runtime %manifest))
(define recovery
  (sk:run-fixture-runtime! recovery-runtime "fixture-recover"))
(check-equal (result-ref recovery 'result) "COMPLETE"
             "recovery result")
(check-equal (result-ref recovery 'terminal) "ROLLED-BACK"
             "recovery terminal")
(check (sk:legal-journal-prefix?
        %manifest (result-ref recovery 'history))
       "recovery terminal history is illegal")
(check (recorded? (result-ref recovery 'history) "ROLLBACK-BEGIN")
       "recovery did not enter rollback")
(check (member "effect:grub-restore"
               (result-ref recovery 'executed-phases))
       "recovery did not invoke GRUB restore")
(check (member "effect:bootcfg-restore"
               (result-ref recovery 'executed-phases))
       "recovery did not invoke bootcfg restore")
(check (= (result-ref recovery 'opened) 1)
       "recovery one session open")
(check (= (result-ref recovery 'closed) 1)
       "recovery one session close")
(check (= (result-ref recovery 'lock-scopes) 1)
       "recovery one lock scope")
(assert-exact-guards recovery "recovery")

;; Unknown actions fail before session construction and do not consume the
;; runtime; a later exact action remains eligible.
(define action-runtime (sk:make-fixture-runtime %manifest))
(check (fails?
        (lambda ()
          (sk:run-fixture-runtime!
           action-runtime "fixture-production-apply")))
       "unknown fixture action was accepted")
(check-equal (sk:fixture-runtime-timeline action-runtime) '()
             "unknown action reached the runtime")
(check-equal
 (result-ref
  (sk:run-fixture-runtime! action-runtime "fixture-apply")
  'terminal)
 "COMPLETE"
 "exact action after unknown-action refusal")

;; A completed or failed run consumes its one store-session model.
(check (fails?
        (lambda ()
          (sk:run-fixture-runtime!
           action-runtime "fixture-apply")))
       "consumed fixture runtime was reusable")

;; Each history below has an exact header, contiguous sequence numbers, valid
;; subjects, and a recomputed predecessor/digest chain.  Only its automaton
;; order is illegal.  The engine's first journal observation must reject it
;; before a root, journal, semantic, or cleanup phase effect.
(define illegal-histories
  (list
   (list "duplicate"
         '(("BEGIN" "-")
           ("BACKUP-DONE" "-")
           ("BACKUP-DONE" "-")))
   (list "reordered"
         '(("BEGIN" "-")
           ("ROOTS-READY" "-")
           ("BACKUP-DONE" "-")))
   (list "skipped"
         '(("BEGIN" "-")
           ("GRUB-REPLACE-INTENT" "-")))
   (list "terminal-suffix"
         (append %normal '(("BACKUP-DONE" "-"))))
   (list "duplicate-terminal"
         (append %normal '(("COMPLETE" "-"))))))

(for-each
 (lambda (case)
   (let* ((label (car case))
          (raw (unsafe-render-hash-valid-journal (cadr case)))
          (runtime
           (sk:make-fixture-runtime %manifest #:journal raw)))
     (check (physically-hash-valid? raw)
            (string-append label " chain is not physically valid"))
     (check (fails?
             (lambda ()
               (sk:run-fixture-runtime!
                runtime "fixture-recover")))
            (string-append label " illegal history was accepted"))
     (check
      (not
       (any
        (lambda (item)
          (and (pair? item) (eq? (car item) 'effect)))
        (sk:fixture-runtime-timeline runtime)))
      (string-append label " phase effect ran before rejection"))
     (check-equal
      (sk:fixture-runtime-timeline runtime)
      '((control session-open) (control session-close))
      (string-append label " rejection boundary"))
     (check (fails?
             (lambda ()
               (sk:run-fixture-runtime!
                runtime "fixture-recover")))
            (string-append label " rejected runtime was reusable"))))
 illegal-histories)

;; A physically corrupt raw journal also fails during read-only verification,
;; without opening a synthetic session or consuming the runtime.
(let ((runtime
       (sk:make-fixture-runtime
        %manifest
        #:journal
        (string-append
         (unsafe-render-hash-valid-journal '(("BEGIN" "-")))
         "corrupt\n"))))
  (check (fails? (lambda () (sk:verify-fixture-runtime runtime)))
         "corrupt journal passed verification")
  (check-equal (sk:fixture-runtime-timeline runtime) '()
               "corrupt verification opened or mutated runtime"))

(format
 #t
 "~a: PASS (~a checks forward-effects=~a recovery-effects=~a illegal-chains=~a)~%"
 %program
 %checks
 (result-ref forward 'effect-count)
 (result-ref recovery 'effect-count)
 (length illegal-histories))
