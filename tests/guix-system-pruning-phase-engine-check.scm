;;; Integrated synthetic tests for the D4a phase engine.

(use-modules (sk system-pruning-boundary)
             (sk system-pruning-orchestrator)
             (sk system-pruning-phase-engine)
             (sk system-pruning-reconciliation)
             (sk system-pruning-root-backend)
             (srfi srfi-1))

(define %program "guix-system-pruning-phase-engine-check")
(define %sha (make-string 64 #\a))
(define %program-target
  "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system-pruning-loaded.scm")
(define %roots
  '(("candidate" "candidate-g1" "1"
     "/gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-system")
    ("bootcfg-old" "old-bootcfg" "-"
     "/gnu/store/cccccccccccccccccccccccccccccccc-grub.cfg")
    ("bootcfg-new" "new-bootcfg" "-"
     "/gnu/store/dddddddddddddddddddddddddddddddd-grub.cfg")))

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

(define (alist-get alist key)
  (let ((entry (assq key alist)))
    (or (and entry (cdr entry))
        (fail "test world lacks ~s" key))))

(define (recorded? history name)
  (any (lambda (event) (string=? (car event) name)) history))

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
(define %committed-index
  (list-index (lambda (event) (string=? (car event) "COMMITTED"))
              %normal))
(define %cleanup
  (drop %normal (+ %committed-index 1)))
(define %registry (sk:phase-engine-phase-registry %roots))
(define %reconciliation-count (length sk:reconciliation-phase-labels))
(define %transaction-phases (drop %registry %reconciliation-count))
(define %rollback-traces
  (filter
   (lambda (trace) (recorded? trace "ROLLBACK-BEGIN"))
   (sk:legal-journal-traces %manifest)))

(check-equal
 (take %registry %reconciliation-count)
 sk:reconciliation-phase-labels
 "reconciliation phases are not the exact registry prefix")
(check (= (length %registry) (length (delete-duplicates %registry)))
       "phase registry contains duplicates")

(define (root-removal-intent? event)
  (and (pair? event)
       (member (car event)
               '("ROOT-REMOVE-INTENT"
                 "ROLLBACK-ROOT-REMOVE-INTENT"))))

(define (root-tuple-by-name name)
  (or
   (find
    (lambda (tuple) (string=? (basename (car tuple)) name))
    (sk:orchestrator-recovery-root-tuples %manifest))
   (fail "root tuple is absent: ~a" name)))

(define (assert-root-was-not-recreated world name label)
  (let* ((tuple (root-tuple-by-name name))
         (root (car tuple))
         (target (cadr tuple))
         (timeline ((alist-get world 'timeline))))
    (check
     (not
      (any
       (lambda (event)
         (or (equal? event `(backend temporary-root ,target))
             (and (>= (length event) 3)
                  (equal? (take event 2) '(backend create-root))
                  (string=? (list-ref event 2) root))))
       timeline))
     (string-append label " recreated or temporarily pinned removed root"))))

(define (immediate-child? namespace root)
  (let ((prefix (string-append namespace "/")))
    (and (string-prefix? prefix root)
         (not
          (string-contains
           (substring root (string-length prefix))
           "/")))))

(define* (make-world history
                     #:key
                     (root-mode 'full)
                     (refuse-phase #f)
                     (lock-accept? #t)
                     (initial-postflight? #f))
  (let* ((all-tuples (sk:orchestrator-root-tuples %manifest))
         (program-tuple (car all-tuples))
         (recovery-tuples (cdr all-tuples))
         (namespace (sk:orchestrator-root-namespace %manifest))
         (done-names
          (filter-map
           (lambda (event)
             (and (member (car event)
                          '("ROOT-REMOVE-DONE"
                            "ROLLBACK-ROOT-REMOVE-DONE"))
                  (cadr event)))
           history))
         (intent-name
          (and (pair? history)
               (member (car (last history))
                       '("ROOT-REMOVE-INTENT"
                         "ROLLBACK-ROOT-REMOVE-INTENT"))
               (cadr (last history))))
         (removed-names
          (if (eq? root-mode 'history-intent-removed)
              (if intent-name
                  (append done-names (list intent-name))
                  (fail
                   "history-intent-removed requires a final removal intent"))
              done-names))
         (terminal?
          (and (pair? history)
               (member (car (last history))
                       '("COMPLETE" "ROLLED-BACK"))))
         (remaining
          (filter
           (lambda (tuple)
             (not (member (basename (car tuple)) removed-names)))
           recovery-tuples))
         (initial-tuples
          (case root-mode
            ((absent) '())
            ((full) all-tuples)
            ((history history-intent-removed)
             (append (list program-tuple)
                     (if terminal? '() remaining)))
            ((program-only) (list program-tuple))
            ((terminal-removed) '())
            (else (fail "unknown synthetic root mode: ~s" root-mode))))
         (namespace?
          (case root-mode
            ((absent) #f)
            ((full) #t)
            ((history history-intent-removed) (not terminal?))
            ((program-only) #t)
            ((terminal-removed) #f)
            (else #f)))
         (direct (map (lambda (tuple) (cons (car tuple) (cadr tuple)))
                      initial-tuples))
         (registered
          (map (lambda (tuple) (cons (car tuple) (cadr tuple)))
               initial-tuples))
         (valid (map cadr all-tuples))
         (live
          (if (member root-mode '(absent terminal-removed))
              '()
              (map cadr all-tuples)))
         (temporary '())
         (journal history)
         (postflight? initial-postflight?)
         (timeline '())
         (opened 0)
         (closed 0)
         (lock-calls 0))
    (define (record! event)
      (set! timeline (cons event timeline))
      #t)
    (define (lookup tuples root)
      (and=> (assoc root tuples) cdr))
    (define (enumerate tuples)
      (map (lambda (entry) (list (car entry) (cdr entry)))
           (filter
            (lambda (entry) (immediate-child? namespace (car entry)))
            tuples)))
    (define backend
      (sk:make-root-backend
       #:name "phase-engine-synthetic"
       #:open
       (lambda ()
         (set! opened (+ opened 1))
         (record! '(backend open))
         'one-session)
       #:close
       (lambda (_token)
         (set! closed (+ closed 1))
         (record! '(backend close)))
       #:add-temp-root!
       (lambda (_token target)
         (set! temporary (cons target temporary))
         (set! live (cons target live))
         (record! `(backend temporary-root ,target)))
       #:direct-root-target
       (lambda (_token root) (lookup direct root))
       #:registered-root-target
       (lambda (_token root) (lookup registered root))
       #:direct-roots
       (lambda (_token _namespace) (enumerate direct))
       #:registered-roots
       (lambda (_token _namespace) (enumerate registered))
       #:namespace-state
       (lambda (_token _namespace)
         (if namespace? 'directory 'absent))
       #:create-namespace!
       (lambda (_token _namespace)
         (set! namespace? #t)
         (record! '(backend create-namespace)))
       #:remove-namespace!
       (lambda (_token _namespace)
         (and (null? (enumerate direct))
              (begin
                (set! namespace? #f)
                (record! '(backend remove-namespace)))))
       #:namespace-empty?
       (lambda (_token _namespace)
         (and (null? (enumerate direct))
              (null? (enumerate registered))))
       #:create-direct-root!
       (lambda (_token root target)
         (set! direct (acons root target (alist-delete root direct)))
         (record! `(backend create-root ,root ,target)))
       #:remove-direct-root!
       (lambda (_token root target)
         (let ((actual (lookup direct root)))
           (and actual
                (string=? actual target)
                (begin
                  (set! direct (alist-delete root direct))
                  (set! registered (alist-delete root registered))
                  (record! `(backend remove-root ,root ,target))))))
       #:valid-path?
       (lambda (_token target) (and (member target valid) #t))
       #:live-path?
       (lambda (_token target) (and (member target live) #t))
       #:sync-parent!
       (lambda (_token root)
         (let ((target (lookup direct root)))
           (if target
               (set! registered
                     (acons root target (alist-delete root registered)))
               (set! registered (alist-delete root registered))))
         (record! `(backend sync ,root)))))
    (define effects
      `((call-with-locks
         . ,(lambda (_state thunk)
              (set! lock-calls (+ lock-calls 1))
              (record! '(locks acquire))
              (if lock-accept?
                  (let ((result (thunk)))
                    (record! '(locks release))
                    result)
                  (begin
                    (record! '(locks refused))
                    #f))))
        (journal-history . ,(lambda (_state) journal))
        (append-journal!
         . ,(lambda (_state event subject)
              (set! journal
                    (append journal (list (list event subject))))
              (record! `(journal ,event ,subject))))
        (old-grub-backup!
         . ,(lambda (_state) (record! '(effect old-grub-backup))))
        (grub!
         . ,(lambda (_state direction)
              (record! `(effect grub ,direction))))
        (bootcfg!
         . ,(lambda (_state direction)
              (record! `(effect bootcfg ,direction))))
        (link!
         . ,(lambda (_state operation subject)
              (record! `(effect link ,operation ,subject))))
        (verify!
         . ,(lambda (_state checkpoint)
              (record! `(effect verify ,checkpoint))))
        (terminal-recorded?
         . ,(lambda (_state terminal)
              (and (pair? journal)
                   (string=? (car (last journal)) terminal))))
        (postflight-complete?
         . ,(lambda (_state _terminal) postflight?))
        (postflight!
         . ,(lambda (_state terminal)
              (set! postflight? #t)
              (record! `(effect terminal-postflight ,terminal))))))
    (define validators
      (map
       (lambda (key)
         (cons
          key
          (lambda (_manifest phase _state)
            (let ((accepted?
                   (not (and refuse-phase
                             (string=? phase refuse-phase)))))
              (record! `(guard ,key ,phase ,accepted?))
              accepted?))))
       '(protected journal session quiescence)))
    `((backend . ,backend)
      (effects . ,effects)
      (validators . ,validators)
      (stop . ,(lambda (label) (record! `(stop ,label))))
      (timeline . ,(lambda () (reverse timeline)))
      (history . ,(lambda () journal))
      (postflight? . ,(lambda () postflight?))
      (direct . ,(lambda () direct))
      (registered . ,(lambda () registered))
      (namespace? . ,(lambda () namespace?))
      (temporary . ,(lambda () temporary))
      (opened . ,(lambda () opened))
      (closed . ,(lambda () closed))
      (lock-calls . ,(lambda () lock-calls)))))

(define (run-world world action)
  (sk:call-with-root-session
   (alist-get world 'backend)
   (lambda (session)
     (sk:run-phase-engine!
      session
      %manifest
      action
      'synthetic-state
      (alist-get world 'effects)
      (alist-get world 'validators)
      (alist-get world 'stop)))))

(define (assert-terminal-world world terminal label)
  (check-equal (car (last ((alist-get world 'history)))) terminal
               (string-append label " terminal"))
  (check ((alist-get world 'postflight?))
         (string-append label " terminal postflight"))
  (check (null? ((alist-get world 'direct)))
         (string-append label " direct roots"))
  (check (null? ((alist-get world 'registered)))
         (string-append label " registered roots"))
  (check (not ((alist-get world 'namespace?)))
         (string-append label " namespace"))
  (check (= ((alist-get world 'opened)) 1)
         (string-append label " one open"))
  (check (= ((alist-get world 'closed)) 1)
         (string-append label " one close"))
  (check (= ((alist-get world 'lock-calls)) 1)
         (string-append label " one lock scope")))

;; Fresh forward: program root first, locks second, all managed roots under the
;; same session, exact automaton trace, terminal postflight, program root last.
(define forward-world (make-world '() #:root-mode 'absent))
(check (eq? (run-world forward-world "forward") 'complete)
       "fresh forward did not complete")
(check-equal ((alist-get forward-world 'history))
             %normal
             "fresh forward history")
(assert-terminal-world forward-world "COMPLETE" "fresh forward")
(let* ((timeline ((alist-get forward-world 'timeline)))
       (program-create
        (list-index
         (lambda (event)
           (and (equal? (take event 2) '(backend create-root))
                (string-prefix?
                 "/var/guix/gcroots/p52b-system-prune-program-"
                 (list-ref event 2))))
         timeline))
       (locks
        (list-index (lambda (event) (equal? event '(locks acquire)))
                    timeline))
       (terminal
        (list-index
         (lambda (event) (equal? event '(journal "COMPLETE" "-")))
         timeline))
       (postflight
        (list-index
         (lambda (event)
           (equal? event '(effect terminal-postflight "COMPLETE")))
         timeline))
       (program-remove
        (list-index
         (lambda (event)
           (and (equal? (take event 2) '(backend remove-root))
                (string-prefix?
                 "/var/guix/gcroots/p52b-system-prune-program-"
                 (list-ref event 2))))
         timeline)))
  (check (and program-create locks (< program-create locks))
         "program root was not durable before locks")
  (check (and terminal postflight program-remove
              (< terminal postflight program-remove))
         "terminal/postflight/program-root order differs"))

;; Every legal precommit forward prefix deterministically selects its
;; state-dependent rollback trace.
(for-each
 (lambda (length)
   (let* ((prefix (take %normal length))
          (world (make-world prefix #:root-mode 'full)))
     (check (eq? (run-world world "recover") 'complete)
            "precommit prefix did not recover")
     (check (string=? (car (last ((alist-get world 'history))))
                      "ROLLED-BACK")
            "precommit prefix did not roll back")
     (check (sk:legal-journal-prefix?
             %manifest ((alist-get world 'history)))
            "rollback result is outside the automaton")
     (assert-terminal-world
      world "ROLLED-BACK"
      (format #f "rollback prefix ~a" length))))
 (iota %committed-index 1))

;; Restart every prefix after ROLLBACK-BEGIN across every state-dependent
;; rollback trace.  A removal INTENT is legal both before the direct root is
;; removed and after removal but before its synchronized DONE append.
(define %rollback-restart-prefixes 0)
(for-each
 (lambda (trace)
   (let ((rollback-index
          (list-index
           (lambda (event) (string=? (car event) "ROLLBACK-BEGIN"))
           trace)))
     (for-each
      (lambda (length)
        (set! %rollback-restart-prefixes
              (+ %rollback-restart-prefixes 1))
        (let* ((prefix (take trace length))
               (world (make-world prefix #:root-mode 'history))
               (label
                (format #f "rollback restart trace-head ~a length ~a"
                        rollback-index length)))
          (check (eq? (run-world world "recover") 'complete)
                 (string-append label " did not complete"))
          (check-equal ((alist-get world 'history))
                       trace
                       (string-append label " history"))
          (assert-terminal-world world "ROLLED-BACK" label)
          (when (root-removal-intent? (last prefix))
            (let* ((name (cadr (last prefix)))
                   (removed-world
                    (make-world
                     prefix
                     #:root-mode 'history-intent-removed))
                   (removed-label
                    (string-append label " after direct removal")))
              (check
               (eq? (run-world removed-world "recover") 'complete)
               (string-append removed-label " did not complete"))
              (check-equal
               ((alist-get removed-world 'history))
               trace
               (string-append removed-label " history"))
              (assert-root-was-not-recreated
               removed-world name removed-label)
              (assert-terminal-world
               removed-world "ROLLED-BACK" removed-label)))))
      (iota (- (length trace) rollback-index)
            (+ rollback-index 1)))))
 %rollback-traces)

;; Every normal post-COMMITTED cleanup journal prefix, including terminal,
;; resumes without recreating an already removed managed root.
(for-each
 (lambda (cleanup-length)
   (let* ((prefix
           (take %normal (+ %committed-index 1 cleanup-length)))
          (world (make-world prefix #:root-mode 'history)))
     (check (eq? (run-world world "recover") 'complete)
            "postcommit cleanup prefix did not recover")
     (check (string=? (car (last ((alist-get world 'history))))
                      "COMPLETE")
            "postcommit cleanup prefix did not complete")
     (check (sk:legal-journal-prefix?
             %manifest ((alist-get world 'history)))
            "postcommit result is outside the automaton")
     (assert-terminal-world
      world "COMPLETE"
      (format #f "postcommit prefix ~a" cleanup-length))
     (when (root-removal-intent? (last prefix))
       (let* ((name (cadr (last prefix)))
              (removed-world
               (make-world
                prefix
                #:root-mode 'history-intent-removed))
              (label
               (format #f
                       "postcommit prefix ~a after direct removal"
                       cleanup-length)))
         (check (eq? (run-world removed-world "recover") 'complete)
                (string-append label " did not complete"))
         (check (sk:legal-journal-prefix?
                 %manifest ((alist-get removed-world 'history)))
                (string-append label " left the automaton"))
         (assert-root-was-not-recreated removed-world name label)
         (assert-terminal-world removed-world "COMPLETE" label)))))
 (iota (+ (length %cleanup) 1)))

;; Lock refusal occurs after the program root but before namespace/root
;; bootstrap, BEGIN, or any semantic effect.
(let ((world
       (make-world '()
                   #:root-mode 'absent
                   #:lock-accept? #f)))
  (check (fails? (lambda () (run-world world "forward")))
         "lock refusal was accepted")
  (check (not ((alist-get world 'namespace?)))
         "recovery namespace was created after lock refusal")
  (check (null? ((alist-get world 'history)))
         "journal began after lock refusal")
  (check (= (length ((alist-get world 'direct))) 1)
         "program root was not the only persistent effect after lock refusal"))

;; Build complete phase coverage from the three closed action families.
(define (scenario-world name refuse)
  (cond
   ((eq? name 'forward)
    (make-world '() #:root-mode 'absent #:refuse-phase refuse))
   ((eq? name 'rollback)
    (make-world
     (take %normal %committed-index)
     #:root-mode 'full
     #:refuse-phase refuse))
   ((eq? name 'postcommit)
    (make-world
     (take %normal (+ %committed-index 1))
     #:root-mode 'history
     #:refuse-phase refuse))
   (else (fail "unknown coverage scenario: ~s" name))))

(define (run-scenario name refuse)
  (let ((world (scenario-world name refuse)))
    (if refuse
        (check (fails? (lambda ()
                         (run-world world
                                    (if (eq? name 'forward)
                                        "forward"
                                        "recover"))))
               (format #f "phase refusal did not fail: ~a" refuse))
        (run-world world
                   (if (eq? name 'forward) "forward" "recover")))
    world))

(define coverage '())
(for-each
 (lambda (scenario)
   (let ((world (run-scenario scenario #f)))
     (for-each
      (lambda (event)
        (when (and (pair? event) (eq? (car event) 'guard))
          (let ((phase (list-ref event 2)))
            (unless (assoc phase coverage)
              (set! coverage
                    (acons phase scenario coverage))))))
      ((alist-get world 'timeline)))))
 '(forward rollback postcommit))

(check-equal
 (sort (map car coverage) string<?)
 (sort (list-copy %transaction-phases) string<?)
 "declared transaction-phase coverage")

;; Refuse the protected guard immediately before every declared phase.  The
;; unified timeline may contain only session close after that refusal marker.
(for-each
 (lambda (phase)
   (let* ((scenario (cdr (assoc phase coverage)))
          (world (run-scenario scenario phase))
          (timeline ((alist-get world 'timeline)))
          (index
           (list-index
            (lambda (event)
              (equal? event `(guard protected ,phase #f)))
            timeline)))
     (check index (format #f "refusal marker absent: ~a" phase))
     (check
      (every (lambda (event) (equal? event '(backend close)))
             (drop timeline (+ index 1)))
      (format #f "effect ran after refused phase: ~a" phase))
     (check (= ((alist-get world 'opened)) 1)
            (format #f "refusal opened multiple sessions: ~a" phase))
     (check (= ((alist-get world 'closed)) 1)
            (format #f "refusal did not close session: ~a" phase))))
 %transaction-phases)

;; A shape-valid but semantically illegal history is rejected before the
;; program root, lock scope, journal, or semantic callbacks can mutate state.
(let* ((history '(("BEGIN" "-") ("COMMITTED" "-")))
       (world (make-world history #:root-mode 'full)))
  (check (fails? (lambda () (run-world world "recover")))
         "illegal recomputed semantic history was accepted")
  (check (= ((alist-get world 'lock-calls)) 0)
         "locks ran before illegal-history rejection")
  (check
   (not
    (any (lambda (event)
           (and (pair? event)
                (member (car event) '(journal effect locks))))
         ((alist-get world 'timeline))))
   "effect ran before illegal-history rejection")
  (check (null? ((alist-get world 'temporary)))
         "a target was pinned before illegal-history rejection"))

;; A legal journal with an impossible managed-root set is rejected before the
;; program target is pinned, locks are acquired, or any phase gate/effect runs.
(let* ((history (take %normal (+ %committed-index 1)))
       (world (make-world history #:root-mode 'program-only)))
  (check (fails? (lambda () (run-world world "recover")))
         "journal/root mismatch was accepted")
  (check (= ((alist-get world 'lock-calls)) 0)
         "locks ran before journal/root mismatch rejection")
  (check (null? ((alist-get world 'temporary)))
         "a target was pinned before journal/root mismatch rejection")
  (check
   (every
    (lambda (event)
      (member event '((backend open) (backend close))))
    ((alist-get world 'timeline)))
   "a gate or effect ran before journal/root mismatch rejection"))

;; If interruption occurs after the durable program root is deleted but before
;; its parent synchronization, terminal+postflight reentry must synchronize
;; once under locks.  It must not pin, recreate, or remove the absent root.
(let* ((program (car (sk:orchestrator-root-tuples %manifest)))
       (program-root (car program))
       (program-target (cadr program))
       (world
        (make-world
         %normal
         #:root-mode 'terminal-removed
         #:initial-postflight? #t)))
  (check (eq? (run-world world "recover") 'complete)
         "program-root delete-before-sync recovery did not complete")
  (check-equal ((alist-get world 'history))
               %normal
               "program-root delete-before-sync history")
  (assert-terminal-world
   world "COMPLETE" "program-root delete-before-sync")
  (let* ((timeline ((alist-get world 'timeline)))
         (sync-events
          (filter
           (lambda (event)
             (and (>= (length event) 2)
                  (equal? (take event 2) '(backend sync))))
           timeline)))
    (check-equal
     sync-events
     `((backend sync ,program-root))
     "program-root delete-before-sync exact synchronization")
    (check (null? ((alist-get world 'temporary)))
           "absent terminal program target was temporarily pinned")
    (check
     (not
      (any
       (lambda (event)
         (or (equal? event `(backend temporary-root ,program-target))
             (and (>= (length event) 3)
                  (member (take event 2)
                          '((backend create-root) (backend remove-root)))
                  (string=? (list-ref event 2) program-root))))
       timeline))
     "absent terminal program root was recreated or removed again")))

(format #t "~a: PASS (~a checks phases=~a rollback-prefixes=~a rollback-restarts=~a cleanup-prefixes=~a)~%"
        %program
        %checks
        (length %registry)
        %committed-index
        %rollback-restart-prefixes
        (+ (length %cleanup) 1))
