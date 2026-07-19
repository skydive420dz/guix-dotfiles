;;; Pure, callback-driven P5.2b-D4a transaction phase engine.

(define-module (sk system-pruning-phase-engine)
  #:use-module (sk system-pruning-boundary)
  #:use-module (sk system-pruning-orchestrator)
  #:use-module (sk system-pruning-reconciliation)
  #:use-module (sk system-pruning-root-backend)
  #:use-module (srfi srfi-1)
  #:export (sk:phase-engine-effect-keys
            sk:phase-engine-error-key
            sk:phase-engine-phase-registry
            sk:phase-engine-required-phases
            sk:assert-phase-engine-manifest
            sk:run-phase-engine!))

(define sk:phase-engine-error-key 'sk-system-pruning-phase-engine)

(define sk:phase-engine-effect-keys
  '(call-with-locks
    journal-history
    append-journal!
    old-grub-backup!
    grub!
    bootcfg!
    link!
    verify!
    terminal-recorded?
    postflight-complete?
    postflight!))

(define (%fail format-string . arguments)
  (throw sk:phase-engine-error-key
         (apply format #f format-string arguments)))

(define (ensure condition format-string . arguments)
  (unless condition
    (apply %fail format-string arguments)))

(define (alist-value alist key)
  (let ((entry (assq key alist)))
    (ensure entry "missing phase-engine record: ~s" key)
    (cdr entry)))

(define (manifest-value manifest key)
  (let ((entry (assq key manifest)))
    (ensure entry "missing boundary-manifest record: ~s" key)
    (cdr entry)))

(define %generic-journal-events
  '("BEGIN"
    "BACKUP-DONE"
    "ROOTS-READY"
    "GRUB-REPLACE-INTENT"
    "GRUB-REPLACE-DONE"
    "BOOTCFG-PROMOTE-INTENT"
    "BOOTCFG-PROMOTE-DONE"
    "LINK-EXCLUDE-INTENT"
    "LINK-EXCLUDE-DONE"
    "LINKS-STAGED"
    "LINK-DISCARD-INTENT"
    "LINK-DISCARD-DONE"
    "LINKS-COMMITTED"
    "POSTFLIGHT-VERIFIED"
    "COMMITTED"
    "ROLLBACK-BEGIN"
    "LINK-RESTORE-INTENT"
    "LINK-RESTORE-DONE"
    "LINKS-RESTORED"
    "GRUB-RESTORE-INTENT"
    "GRUB-RESTORE-DONE"
    "BOOTCFG-RESTORE-INTENT"
    "BOOTCFG-RESTORE-DONE"
    "PRESTATE-VERIFIED"
    "FORWARD-RECOVERY-BEGIN"))

(define (assert-root-records roots)
  (ensure (and (list? roots) (>= (length roots) 3))
          "phase registry requires candidate plus old/new bootcfg roots")
  (for-each
   (lambda (root)
     (ensure (and (list? root)
                  (= (length root) 4)
                  (string? (cadr root))
                  (string? (list-ref root 2)))
             "phase registry root has an invalid shape: ~s"
             root))
   roots)
  roots)

(define (candidate-subjects roots)
  (map (lambda (root) (list-ref root 2))
       (drop-right roots 2)))

(define (root-names roots)
  (map cadr roots))

(define (bootstrap-phases roots)
  (append
   '("temporary-root:program-root"
     "create-root:program-root"
     "sync-root:program-root"
     "create-root-namespace")
   (append-map
    (lambda (name)
      (list (string-append "temporary-root:" name)
            (string-append "create-root:" name)
            (string-append "sync-root:" name)))
    (root-names roots))))

(define (semantic-phases roots)
  (append
   '("effect:old-grub-backup"
     "effect:roots-ready"
     "effect:grub-replace"
     "effect:bootcfg-promote"
     "effect:links-staged")
   (append-map
    (lambda (subject)
      (list (string-append "effect:link-exclude:" subject)
            (string-append "effect:link-discard:" subject)
            (string-append "effect:link-restore:" subject)))
    (candidate-subjects roots))
   '("effect:links-committed"
     "effect:forward-postflight"
     "effect:links-restored"
     "effect:grub-restore"
     "effect:bootcfg-restore"
     "effect:rollback-prestate")))

(define (journal-phases)
  (map (lambda (name) (string-append "append-journal:" name))
       %generic-journal-events))

(define (cleanup-phases roots)
  (append
   (append-map
    (lambda (name)
      (list (string-append "append-root-remove-intent:" name)
            (string-append "remove-root:" name)
            (string-append "sync-root-removal:" name)
            (string-append "append-root-remove-done:" name)))
    (root-names roots))
   '("remove-root-namespace"
     "append-terminal:COMPLETE"
     "terminal-postflight:COMPLETE"
     "append-terminal:ROLLED-BACK"
     "terminal-postflight:ROLLED-BACK"
     "remove-root:program-root"
     "sync-root-removal:program-root")))

(define (sk:phase-engine-phase-registry roots)
  "Return the deterministic phase registry for ordered boundary ROOTS.

ROOTS has the same candidate-plus-old/new-bootcfg shape later validated by the
boundary manifest.  This constructor does not require a partially constructed
manifest, so the fused driver can use it directly in the manifest's `phases'
  field."
  (let* ((roots (assert-root-records roots))
         (phases
          (append sk:reconciliation-phase-labels
                  (bootstrap-phases roots)
                  (semantic-phases roots)
                  (journal-phases)
                  (cleanup-phases roots))))
    (ensure (= (length phases) (length (delete-duplicates phases)))
            "phase-engine registry contains duplicate labels")
    phases))

(define (sk:phase-engine-required-phases manifest)
  "Return the exact phase registry for MANIFEST's closed root/event model.

This compatibility helper validates MANIFEST and delegates to
`sk:phase-engine-phase-registry'."
  (sk:assert-boundary-manifest manifest)
  (sk:phase-engine-phase-registry (sk:boundary-roots manifest)))

(define (sk:assert-phase-engine-manifest manifest)
  "Validate MANIFEST and its exact, complete phase-engine registry."
  (sk:assert-boundary-manifest manifest)
  (ensure
   (equal? (manifest-value manifest 'phases)
           (sk:phase-engine-required-phases manifest))
   "boundary phase registry differs from the exact phase-engine registry")
  manifest)

(define (assert-effects effects)
  (ensure (and (list? effects)
               (equal? (map car effects) sk:phase-engine-effect-keys))
          "phase-engine effects differ from the closed callback set")
  (for-each
   (lambda (entry)
     (ensure (procedure? (cdr entry))
             "phase-engine effect is not a procedure: ~s"
             (car entry)))
   effects)
  effects)

(define (call-exact-success procedure label . arguments)
  (ensure (eq? (apply procedure arguments) #t)
          "phase-engine callback did not return exact success: ~a"
          label)
  #t)

(define (call-exact-boolean procedure label . arguments)
  (let ((result (apply procedure arguments)))
    (ensure (boolean? result)
            "phase-engine observation returned a non-boolean: ~a"
            label)
    result))

(define (list-prefix? prefix whole)
  (and (<= (length prefix) (length whole))
       (equal? prefix (take whole (length prefix)))))

(define (history-has? history name)
  (any (lambda (event) (string=? (car event) name)) history))

(define (terminal-history? history)
  (and (pair? history)
       (member (car (last history)) '("COMPLETE" "ROLLED-BACK"))))

(define (cleanup-event? event)
  (let ((name (car event)))
    (or (member name '("COMPLETE" "ROLLED-BACK"))
        (string-prefix? "ROOT-REMOVE-" name)
        (string-prefix? "ROLLBACK-ROOT-REMOVE-" name))))

(define (normal-forward-trace manifest)
  (let ((trace
         (find
          (lambda (candidate)
            (and (history-has? candidate "COMMITTED")
                 (history-has? candidate "COMPLETE")
                 (not (history-has? candidate "FORWARD-RECOVERY-BEGIN"))
                 (not (history-has? candidate "ROLLBACK-BEGIN"))))
          (sk:legal-journal-traces manifest))))
    (ensure trace "closed automaton has no normal forward trace")
    trace))

(define (continuation-trace manifest history terminal)
  (let ((matches
         (filter
          (lambda (trace)
            (and (list-prefix? history trace)
                 (string=? (car (last trace)) terminal)))
          (sk:legal-journal-traces manifest))))
    (ensure (= (length matches) 1)
            "history has no unique ~a continuation"
            terminal)
    (car matches)))

(define (phase-stop stop label)
  (ensure (procedure? stop) "phase-engine stop callback is not a procedure")
  (ensure (eq? (stop label) #t)
          "phase-engine stop callback refused boundary: ~a"
          label)
  #t)

(define (program-tuple manifest)
  (car (sk:orchestrator-root-tuples manifest)))

(define (observed-root-state session manifest)
  (let* ((program (program-tuple manifest))
         (program-root (car program))
         (program-target (cadr program))
         (direct-target
          (sk:root-session-direct-root-target session program-root))
         (registered-target
          (sk:root-session-registered-root-target session program-root))
         (namespace (sk:orchestrator-root-namespace manifest))
         (namespace-state
          (sk:root-session-namespace-state session namespace))
         (direct
          (if (eq? namespace-state 'directory)
              (sk:root-session-direct-roots session namespace)
              '()))
         (registered
          (if (eq? namespace-state 'directory)
              (sk:root-session-registered-roots session namespace)
              '())))
    (ensure (or (not direct-target)
                (string=? direct-target program-target))
            "direct program root is retargeted")
    (ensure (or (not registered-target)
                (string=? registered-target program-target))
            "registered program root is retargeted")
    (ensure (eq? (and direct-target #t) (and registered-target #t))
            "direct and registered program-root states differ")
    (let ((observed
           `((program-direct . ,(and direct-target program))
             (program-registered . ,(and registered-target program))
             (namespace . ,namespace-state)
             (direct-roots . ,direct)
             (registered-roots . ,registered))))
      (sk:assert-orchestrator-root-set session manifest observed)
      observed)))

(define (program-present? root-state)
  (and (alist-value root-state 'program-direct)
       (alist-value root-state 'program-registered)
       #t))

(define (sorted-tuples tuples)
  (sort (map (lambda (tuple) (list (car tuple) (cadr tuple))) tuples)
        (lambda (left right) (string<? (car left) (car right)))))

(define (same-tuples? left right)
  (equal? (sorted-tuples left) (sorted-tuples right)))

(define (cleanup-family history)
  (cond
   ((history-has? history "ROLLBACK-BEGIN") 'rollback)
   ((history-has? history "COMMITTED") 'forward)
   (else #f)))

(define (cleanup-root-event? family event)
  (let ((name (car event)))
    (case family
      ((forward)
       (member name '("ROOT-REMOVE-INTENT" "ROOT-REMOVE-DONE")))
      ((rollback)
       (member name
               '("ROLLBACK-ROOT-REMOVE-INTENT"
                 "ROLLBACK-ROOT-REMOVE-DONE")))
      (else #f))))

(define (cleanup-done-event? family event)
  (let ((name (car event)))
    (case family
      ((forward) (string=? name "ROOT-REMOVE-DONE"))
      ((rollback) (string=? name "ROLLBACK-ROOT-REMOVE-DONE"))
      (else #f))))

(define (cleanup-intent-event? family event)
  (let ((name (car event)))
    (case family
      ((forward) (string=? name "ROOT-REMOVE-INTENT"))
      ((rollback) (string=? name "ROLLBACK-ROOT-REMOVE-INTENT"))
      (else #f))))

(define (allowed-remaining-root-sets manifest history)
  (let* ((expected (sk:orchestrator-recovery-root-tuples manifest))
         (family (cleanup-family history))
         (events
          (if family
              (filter
               (lambda (event) (cleanup-root-event? family event))
               history)
              '()))
         (done-count
          (count (lambda (event) (cleanup-done-event? family event))
                 events))
         (removed-counts
          (if (and (pair? events)
                   (cleanup-intent-event? family (last events)))
              (list done-count (+ done-count 1))
              (list done-count))))
    (ensure (every (lambda (count)
                     (and (>= count 0) (<= count (length expected))))
                   removed-counts)
            "journal cleanup count exceeds the closed root set")
    (delete-duplicates
     (map (lambda (count) (drop expected count)) removed-counts))))

(define (assert-history-root-state manifest history observed)
  (let* ((direct (alist-value observed 'direct-roots))
         (registered (alist-value observed 'registered-roots))
         (namespace (alist-value observed 'namespace))
         (allowed (allowed-remaining-root-sets manifest history))
         (remaining
          (find (lambda (candidate) (same-tuples? direct candidate))
                allowed))
         (terminal? (terminal-history? history)))
    (ensure (same-tuples? direct registered)
            "journal recovery direct and registered roots differ")
    (ensure remaining
            "journal cleanup and remaining recovery roots differ")
    (if (pair? remaining)
        (ensure (eq? namespace 'directory)
                "remaining recovery roots have no exact namespace")
        (if terminal?
            (ensure (eq? namespace 'absent)
                    "terminal journal retains its recovery-root namespace")
            (ensure (memq namespace '(absent directory))
                    "empty recovery-root namespace state is invalid")))
    (unless terminal?
      (ensure (program-present? observed)
              "nonterminal journal has no exact durable program root"))
    observed))

(define (run-gated! session manifest phase state validators expected
                    thunk stop)
  (sk:call-with-orchestrator-phase
   session manifest phase state validators thunk expected)
  (phase-stop stop (string-append "after-" phase)))

(define (run-full-root-gated! session manifest phase state validators
                              thunk stop)
  (sk:call-with-orchestrator-phase
   session manifest phase state validators thunk)
  (phase-stop stop (string-append "after-" phase)))

(define (observe-history manifest effects state allow-empty?)
  (let ((history ((alist-value effects 'journal-history) state)))
    (ensure (list? history) "journal-history callback returned a non-list")
    (cond
     ((null? history)
      (ensure allow-empty? "empty journal is not legal for this action")
      history)
     (else
      (sk:assert-legal-journal-history manifest history)))))

(define (append-raw! manifest effects state event allow-begin?)
  (let ((before (observe-history manifest effects state allow-begin?)))
    (if (null? before)
        (ensure (and allow-begin? (equal? event '("BEGIN" "-")))
                "only BEGIN may create the initial journal")
        (sk:assert-legal-journal-successor manifest before event))
    (call-exact-success
     (alist-value effects 'append-journal!)
     (string-append "append-journal:" (car event))
     state
     (car event)
     (cadr event))
    (let ((after (observe-history manifest effects state #f)))
      (ensure (equal? after (append before (list event)))
              "journal callback did not append exactly one successor"))
    #t))

(define* (append-gated! session manifest effects state validators event stop
                        #:optional (expected #f) (allow-begin? #f))
  (let ((phase (string-append "append-journal:" (car event))))
    (if expected
        (run-gated!
         session manifest phase state validators expected
         (lambda ()
           (append-raw! manifest effects state event allow-begin?))
         stop)
        (run-full-root-gated!
         session manifest phase state validators
         (lambda ()
           (append-raw! manifest effects state event allow-begin?))
         stop))))

(define (semantic-effect session manifest effects state validators
                         phase procedure stop)
  (run-full-root-gated!
   session manifest phase state validators
   (lambda () (call-exact-success procedure phase))
   stop))

(define (perform-event-effect! session manifest effects state validators
                               event stop)
  (let ((name (car event))
        (subject (cadr event)))
    (cond
     ((string=? name "BACKUP-DONE")
      (semantic-effect
       session manifest effects state validators
       "effect:old-grub-backup"
       (lambda () ((alist-value effects 'old-grub-backup!) state))
       stop))
     ((string=? name "ROOTS-READY")
      (semantic-effect
       session manifest effects state validators
       "effect:roots-ready"
       (lambda () ((alist-value effects 'verify!) state 'roots-ready))
       stop))
     ((string=? name "GRUB-REPLACE-DONE")
      (semantic-effect
       session manifest effects state validators
       "effect:grub-replace"
       (lambda () ((alist-value effects 'grub!) state 'forward))
       stop))
     ((string=? name "BOOTCFG-PROMOTE-DONE")
      (semantic-effect
       session manifest effects state validators
       "effect:bootcfg-promote"
       (lambda () ((alist-value effects 'bootcfg!) state 'forward))
       stop))
     ((string=? name "LINK-EXCLUDE-DONE")
      (semantic-effect
       session manifest effects state validators
       (string-append "effect:link-exclude:" subject)
       (lambda ()
         ((alist-value effects 'link!) state 'exclude subject))
       stop))
     ((string=? name "LINKS-STAGED")
      (semantic-effect
       session manifest effects state validators
       "effect:links-staged"
       (lambda () ((alist-value effects 'verify!) state 'links-staged))
       stop))
     ((string=? name "LINK-DISCARD-DONE")
      (semantic-effect
       session manifest effects state validators
       (string-append "effect:link-discard:" subject)
       (lambda ()
         ((alist-value effects 'link!) state 'discard subject))
       stop))
     ((string=? name "LINKS-COMMITTED")
      (semantic-effect
       session manifest effects state validators
       "effect:links-committed"
       (lambda () ((alist-value effects 'verify!) state 'links-committed))
       stop))
     ((string=? name "POSTFLIGHT-VERIFIED")
      (semantic-effect
       session manifest effects state validators
       "effect:forward-postflight"
       (lambda ()
         ((alist-value effects 'verify!) state 'forward-postflight))
       stop))
     ((string=? name "LINK-RESTORE-DONE")
      (semantic-effect
       session manifest effects state validators
       (string-append "effect:link-restore:" subject)
       (lambda ()
         ((alist-value effects 'link!) state 'restore subject))
       stop))
     ((string=? name "LINKS-RESTORED")
      (semantic-effect
       session manifest effects state validators
       "effect:links-restored"
       (lambda () ((alist-value effects 'verify!) state 'links-restored))
       stop))
     ((string=? name "GRUB-RESTORE-DONE")
      (semantic-effect
       session manifest effects state validators
       "effect:grub-restore"
       (lambda () ((alist-value effects 'grub!) state 'rollback))
       stop))
     ((string=? name "BOOTCFG-RESTORE-DONE")
      (semantic-effect
       session manifest effects state validators
       "effect:bootcfg-restore"
       (lambda () ((alist-value effects 'bootcfg!) state 'rollback))
       stop))
     ((string=? name "PRESTATE-VERIFIED")
      (semantic-effect
       session manifest effects state validators
       "effect:rollback-prestate"
       (lambda ()
         ((alist-value effects 'verify!) state 'rollback-prestate))
       stop))
     (else #t))))

(define (run-events-until-cleanup!
         session manifest effects state validators target stop)
  (let loop ()
    (let* ((history (observe-history manifest effects state #f))
           (index (length history)))
      (ensure (list-prefix? history target)
              "journal diverged from the selected automaton continuation")
      (cond
       ((= index (length target)) #t)
       ((cleanup-event? (list-ref target index)) #t)
       (else
        (let ((next (list-ref target index)))
          (perform-event-effect!
           session manifest effects state validators next stop)
          (append-gated!
           session manifest effects state validators next stop)
          (loop)))))))

(define (recorded-event? manifest effects state event subject)
  (let ((history (observe-history manifest effects state #f)))
    (and (member (list event subject) history) #t)))

(define (journal-terminal-recorded? manifest effects state terminal)
  (let* ((history (observe-history manifest effects state #f))
         (journal?
          (and (pair? history)
               (string=? (car (last history)) terminal)))
         (external?
          (call-exact-boolean
           (alist-value effects 'terminal-recorded?)
           "terminal-recorded?"
           state terminal)))
    (ensure (eq? (and journal? #t) external?)
            "terminal observation differs from the journal")
    external?))

(define (cleanup! session manifest effects state validators target terminal stop)
  (sk:cleanup-orchestrator-roots!
   session manifest terminal state validators
   (lambda (event subject)
     (recorded-event? manifest effects state event subject))
   (lambda (event subject)
     (append-raw! manifest effects state (list event subject) #f))
   (lambda (observed-terminal)
     (journal-terminal-recorded?
      manifest effects state observed-terminal))
   (lambda (event)
     (append-raw! manifest effects state (list event "-") #f))
   (lambda (observed-terminal)
     (call-exact-boolean
      (alist-value effects 'postflight-complete?)
      "postflight-complete?"
      state observed-terminal))
   (lambda (observed-terminal)
     (call-exact-success
      (alist-value effects 'postflight!)
      "postflight!"
      state observed-terminal))
   stop)
  (let ((history (observe-history manifest effects state #f)))
    (ensure (equal? history target)
            "terminal cleanup did not reach the selected automaton trace"))
  (ensure
   (call-exact-boolean
    (alist-value effects 'postflight-complete?)
    "postflight-complete?"
    state terminal)
   "terminal postflight is not complete")
  'complete)

(define (append-recovery-marker!
         session manifest effects state validators event stop)
  (append-gated!
   session manifest effects state validators event stop
   (observed-root-state session manifest)))

(define (select-recovery-target!
         session manifest effects state validators stop)
  (let ((history (observe-history manifest effects state #f)))
    (cond
     ((terminal-history? history)
      (continuation-trace manifest history (car (last history))))
     ((history-has? history "COMMITTED")
      (unless (history-has? history "FORWARD-RECOVERY-BEGIN")
        (append-recovery-marker!
         session manifest effects state validators
         '("FORWARD-RECOVERY-BEGIN" "-") stop))
      (continuation-trace
       manifest
       (observe-history manifest effects state #f)
       "COMPLETE"))
     (else
      (unless (history-has? history "ROLLBACK-BEGIN")
        (append-gated!
         session manifest effects state validators
         '("ROLLBACK-BEGIN" "-") stop))
      (continuation-trace
       manifest
       (observe-history manifest effects state #f)
       "ROLLED-BACK")))))

(define (call-under-locks effects state thunk)
  (let ((calls 0))
    (let ((result
           ((alist-value effects 'call-with-locks)
            state
            (lambda ()
              (ensure (zero? calls)
                      "call-with-locks invoked its continuation more than once")
              (set! calls (+ calls 1))
              (thunk)))))
      (ensure (= calls 1)
              "call-with-locks did not invoke its continuation exactly once")
      (ensure (eq? result 'complete)
              "call-with-locks did not return the engine result")
      result)))

(define (run-fresh-forward!
         session manifest effects state validators stop)
  (sk:bootstrap-orchestrator-program-root!
   session manifest state validators stop)
  (call-under-locks
   effects state
   (lambda ()
     (sk:bootstrap-orchestrator-recovery-roots!
      session manifest state validators stop)
     (append-gated!
      session manifest effects state validators
      '("BEGIN" "-") stop #f #t)
     (let ((target (normal-forward-trace manifest)))
       (run-events-until-cleanup!
        session manifest effects state validators target stop)
       (cleanup!
        session manifest effects state validators target "COMPLETE" stop)))))

(define (run-recovery!
         session manifest effects state validators stop)
  (let* ((history (observe-history manifest effects state #f))
         (observed
          (assert-history-root-state
           manifest history (observed-root-state session manifest)))
         (terminal? (terminal-history? history))
         (postflight?
          (and terminal?
               (call-exact-boolean
                (alist-value effects 'postflight-complete?)
                "postflight-complete?"
                state
                (car (last history))))))
    (when (not (program-present? observed))
      (ensure (and terminal? postflight?)
              "journal recovery requires the exact durable program root"))
    ;; A durable root surviving a process restart does not preserve the old
    ;; daemon connection's temporary root.  Reuse the orchestrator bootstrap
    ;; path to pin and revalidate it before locks.  The one exact exception is
    ;; terminal+postflight reentry after durable program-root deletion: it must
    ;; not recreate that root and still has to replay parent synchronization.
    (when (program-present? observed)
      (sk:bootstrap-orchestrator-program-root!
       session manifest state validators stop))
    (call-under-locks
     effects state
     (lambda ()
       (when (program-present? observed)
         (sk:pin-orchestrator-remaining-roots!
          session manifest state validators stop))
       (let* ((target
               (select-recovery-target!
                session manifest effects state validators stop))
              (terminal (car (last target))))
         (run-events-until-cleanup!
          session manifest effects state validators target stop)
         (cleanup!
          session manifest effects state validators
          target terminal stop))))))

(define (sk:run-phase-engine!
         session manifest action state effects validators stop)
  "Run one synthetic forward or recovery transaction through the D4a boundary.

SESSION is already open and is never replaced.  EFFECTS is the exact callback
set `sk:phase-engine-effect-keys'.  ACTION is \"forward\" for an empty journal
or \"recover\" for one legal non-empty history.  Every callback is inert until
its phase passes the central protected/journal/root/session/quiescence gate."
  (sk:assert-phase-engine-manifest manifest)
  (assert-effects effects)
  (ensure (member action '("forward" "recover"))
          "unsupported phase-engine action: ~s"
          action)
  (sk:call-with-journal-trace-cache
   manifest
   (lambda ()
     ;; Validate the journal before the first root, lock, or semantic callback.
     (let ((history
            (observe-history
             manifest effects state (string=? action "forward"))))
       (if (string=? action "forward")
           (begin
             (ensure (null? history)
                     "fresh forward action requires an empty journal")
             (run-fresh-forward!
              session manifest effects state validators stop))
           (run-recovery!
            session manifest effects state validators stop))))))
