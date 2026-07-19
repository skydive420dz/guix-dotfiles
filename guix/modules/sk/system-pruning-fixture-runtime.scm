;;; Closed in-memory execution adapter for the P5.2b-D4a phase engine.

(define-module (sk system-pruning-fixture-runtime)
  #:use-module (sk system-pruning-boundary)
  #:use-module (sk system-pruning-orchestrator)
  #:use-module (sk system-pruning-phase-engine)
  #:use-module (sk system-pruning-root-backend)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (sk:fixture-runtime-error-key
            sk:fixture-runtime?
            sk:make-fixture-runtime
            sk:verify-fixture-runtime
            sk:run-fixture-runtime!
            sk:fixture-runtime-timeline
            sk:fixture-runtime-result-ref))

(define sk:fixture-runtime-error-key 'sk-system-pruning-fixture-runtime)

(define %result-schema "p5.2b-system-prune-fixture-runtime-result/v1")
(define %actions '("fixture-apply" "fixture-recover"))
(define %guard-order '(protected journal roots session quiescence))
(define %result-keys
  '(schema mode authorization action manifest-sha result terminal
    declared-phases executed-phases history guard-count effect-count
    opened closed lock-scopes timeline))

(define-record-type <fixture-runtime>
  (%make-fixture-runtime manifest initial-journal used? timeline)
  sk:fixture-runtime?
  (manifest fixture-runtime-manifest)
  (initial-journal fixture-runtime-initial-journal)
  (used? fixture-runtime-used? set-fixture-runtime-used?!)
  (timeline fixture-runtime-timeline set-fixture-runtime-timeline!))

(define (%fail format-string . arguments)
  (throw sk:fixture-runtime-error-key
         (apply format #f format-string arguments)))

(define (ensure condition format-string . arguments)
  (unless condition
    (apply %fail format-string arguments)))

(define (alist-value alist key)
  (let ((entry (assq key alist)))
    (ensure entry "missing fixture-runtime record: ~s" key)
    (cdr entry)))

(define (runtime-state? expected actual)
  (and (list? actual) (equal? expected actual)))

(define (immediate-child? namespace root)
  (let ((prefix (string-append namespace "/")))
    (and (string-prefix? prefix root)
         (not
          (string-contains
           (substring root (string-length prefix))
           "/")))))

(define (normal-forward-trace manifest)
  (let ((trace
         (find
          (lambda (candidate)
            (and (member '("COMMITTED" "-") candidate)
                 (member '("COMPLETE" "-") candidate)
                 (not (member '("FORWARD-RECOVERY-BEGIN" "-") candidate))
                 (not (member '("ROLLBACK-BEGIN" "-") candidate))))
          (sk:legal-journal-traces manifest))))
    (ensure trace "fixture runtime cannot find the normal forward trace")
    trace))

(define (default-recovery-history manifest)
  ;; This exact prefix exercises both GRUB and bootcfg rollback without
  ;; pretending that a rootless or unclassified reconciliation state exists.
  (let* ((trace (normal-forward-trace manifest))
         (index
          (list-index
           (lambda (event)
             (equal? event '("BOOTCFG-PROMOTE-DONE" "-")))
           trace)))
    (ensure index "normal trace lacks BOOTCFG-PROMOTE-DONE")
    (take trace (+ index 1))))

(define* (sk:make-fixture-runtime manifest #:key (journal #f))
  "Return a one-shot, wholly in-memory D4a fixture runtime.

MANIFEST must contain the phase engine's exact closed registry.  JOURNAL is
either false, for the action-specific canonical starting state, or raw
synthetic journal bytes.  Raw bytes are intentionally not trusted here: the
phase engine's first `journal-history' observation parses and authenticates
them before any phase effect."
  (sk:assert-phase-engine-manifest manifest)
  (ensure (or (not journal) (string? journal))
          "fixture-runtime journal is not false or raw text")
  (%make-fixture-runtime manifest journal #f '()))

(define (sk:fixture-runtime-timeline runtime)
  "Return RUNTIME's deterministic audit timeline, including failed runs."
  (ensure (sk:fixture-runtime? runtime)
          "value is not a fixture runtime")
  (list-copy (fixture-runtime-timeline runtime)))

(define (make-result manifest action result terminal declared executed history
                     guards effects opened closed locks timeline)
  `((schema . ,%result-schema)
    (mode . "FIXTURE-ONLY")
    (authorization . "NOT-GRANTED")
    (action . ,action)
    (manifest-sha . ,(alist-value manifest 'manifest-sha))
    (result . ,result)
    (terminal . ,terminal)
    (declared-phases . ,declared)
    (executed-phases . ,executed)
    (history . ,history)
    (guard-count . ,guards)
    (effect-count . ,effects)
    (opened . ,opened)
    (closed . ,closed)
    (lock-scopes . ,locks)
    (timeline . ,timeline)))

(define (assert-result result)
  (ensure (and (list? result)
               (equal? (map car result) %result-keys))
          "fixture-runtime result differs from the closed shape")
  result)

(define (sk:fixture-runtime-result-ref result key)
  "Return KEY from one closed fixture-runtime RESULT."
  (alist-value (assert-result result) key))

(define (sk:verify-fixture-runtime runtime)
  "Validate RUNTIME without opening a root session or invoking an effect."
  (ensure (sk:fixture-runtime? runtime)
          "value is not a fixture runtime")
  (let* ((manifest
          (sk:assert-phase-engine-manifest
           (fixture-runtime-manifest runtime)))
         (journal (fixture-runtime-initial-journal runtime))
         (history (if journal (sk:parse-journal manifest journal) '()))
         (declared (sk:phase-engine-required-phases manifest))
         ;; Construct every injected capability, but do not open the backend
         ;; or invoke any callback.  This validates the closed adapter shape
         ;; while keeping verification observably effect-free.
         (world
          (make-world
           manifest
           "fixture-apply"
           journal
           (lambda (_timeline)
             (%fail "fixture verification invoked a runtime callback")))))
    (when (pair? history)
      (sk:assert-legal-journal-history manifest history))
    (ensure (sk:root-backend? (alist-value world 'backend))
            "fixture verification did not construct a root backend")
    (ensure (equal? (map car (alist-value world 'effects))
                    sk:phase-engine-effect-keys)
            "fixture verification effect callbacks differ")
    (ensure (equal? (map car (alist-value world 'validators))
                    '(protected journal session quiescence))
            "fixture verification validators differ")
    (ensure (procedure? (alist-value world 'stop))
            "fixture verification stop callback is absent")
    (assert-result
     (make-result
      manifest "fixture-verify" "VERIFIED" "-"
      declared '() history 0 0 0 0 0 '()))))

(define (make-world manifest action supplied-journal audit!)
  (let* ((recover? (string=? action "fixture-recover"))
         (all-tuples (sk:orchestrator-root-tuples manifest))
         (namespace (sk:orchestrator-root-namespace manifest))
         (journal
          (or supplied-journal
              (and recover?
                   (sk:render-journal
                    manifest
                    (default-recovery-history manifest)))))
         (initial-tuples (if recover? all-tuples '()))
         (direct
          (map (lambda (tuple) (cons (car tuple) (cadr tuple)))
               initial-tuples))
         (registered
          (map (lambda (tuple) (cons (car tuple) (cadr tuple)))
               initial-tuples))
         (namespace? recover?)
         (valid (map cadr all-tuples))
         (live (if recover? (map cadr all-tuples) '()))
         (temporary '())
         (timeline '())
         (executed-phases '())
         (opened 0)
         (closed 0)
         (lock-scopes 0)
         (session-active? #f)
         (gate-phase #f)
         (gate-guards '())
         (gate-effect-count 0)
         (effect-active? #f)
         (postflight-terminal #f)
         (backup? #f)
         (grub 'old)
         (bootcfg 'old)
         (links
          (map
           (lambda (root)
             (cons (list-ref root 2) 'present))
           (drop-right (sk:boundary-roots manifest) 2)))
         (semantics-initialized? (not recover?))
         (state
          `((schema . "p5.2b-system-prune-fixture-runtime-state/v1")
            (manifest-sha . ,(alist-value manifest 'manifest-sha))
            (action . ,action))))
    (define (record! item)
      (set! timeline (append timeline (list item)))
      (audit! timeline)
      #t)
    (define (lookup tuples root)
      (and=> (assoc root tuples) cdr))
    (define (enumerate tuples)
      (map
       (lambda (entry) (list (car entry) (cdr entry)))
       (filter
        (lambda (entry)
          (immediate-child? namespace (car entry)))
        tuples)))
    (define (assert-state! actual)
      (ensure (runtime-state? state actual)
              "fixture-runtime state identity drift")
      #t)
    (define (guard-record! key phase)
      (set! gate-guards (append gate-guards (list key)))
      (record! `(guard ,phase ,key))
      #t)
    (define (note-root-guard!)
      (when (and gate-phase
                 (equal? gate-guards '(protected journal)))
        (guard-record! 'roots gate-phase))
      #t)
    (define (begin-effect!)
      (ensure gate-phase
              "fixture effect is outside a central phase gate")
      (ensure (equal? gate-guards %guard-order)
              "fixture effect lacks the exact five guards: ~a"
              gate-phase)
      (ensure (zero? gate-effect-count)
              "fixture phase attempted more than one effect: ~a"
              gate-phase)
      (ensure (not effect-active?)
              "fixture phase overlapped another effect: ~a"
              gate-phase)
      #t)
    (define (record-effect! detail)
      (set! gate-effect-count (+ gate-effect-count 1))
      (set! executed-phases
            (append executed-phases (list gate-phase)))
      (record! `(effect ,gate-phase ,@detail))
      #t)
    (define (effect! detail thunk)
      (begin-effect!)
      (let ((result
             (dynamic-wind
               (lambda () (set! effect-active? #t))
               thunk
               (lambda () (set! effect-active? #f)))))
        (ensure (eq? result #t)
                "fixture effect did not return exact success: ~a"
                gate-phase)
        (record-effect! detail)))
    (define (reset-semantics!)
      (set! backup? #f)
      (set! grub 'old)
      (set! bootcfg 'old)
      (set! links
            (map
             (lambda (root)
               (cons (list-ref root 2) 'present))
             (drop-right (sk:boundary-roots manifest) 2))))
    (define (set-link! subject value)
      (ensure (assoc subject links)
              "fixture link subject is unknown: ~a"
              subject)
      (set! links (acons subject value (alist-delete subject links))))
    (define (replay-semantics! history)
      (reset-semantics!)
      (for-each
       (lambda (event)
         (let ((name (car event))
               (subject (cadr event)))
           (cond
            ((string=? name "BACKUP-DONE")
             (set! backup? #t))
            ((string=? name "GRUB-REPLACE-DONE")
             (set! grub 'new))
            ((string=? name "BOOTCFG-PROMOTE-DONE")
             (set! bootcfg 'new))
            ((string=? name "LINK-EXCLUDE-DONE")
             (set-link! subject 'excluded))
            ((string=? name "LINK-DISCARD-DONE")
             (set-link! subject 'discarded))
            ((string=? name "LINK-RESTORE-DONE")
             (set-link! subject 'present))
            ((string=? name "GRUB-RESTORE-DONE")
             (set! grub 'old))
            ((string=? name "BOOTCFG-RESTORE-DONE")
             (set! bootcfg 'old)))))
       history)
      (set! semantics-initialized? #t))
    (define (journal-history!)
      (let ((history
             (if journal
                 (sk:parse-journal manifest journal)
                 '())))
        (unless semantics-initialized?
          (replay-semantics! history))
        history))
    (define (all-links? state-symbol)
      (every (lambda (entry) (eq? (cdr entry) state-symbol)) links))
    (define (phase-validator key expected-prior)
      (lambda (actual-manifest phase actual-state)
        (ensure (equal? actual-manifest manifest)
                "fixture validator received another manifest")
        (assert-state! actual-state)
        (ensure (member phase
                        (sk:phase-engine-required-phases manifest))
                "fixture validator received an undeclared phase: ~a"
                phase)
        (cond
         ((eq? key 'protected)
          (ensure (not gate-phase)
                  "fixture phase overlapped another phase: ~a"
                  gate-phase)
          (set! gate-phase phase)
          (set! gate-guards '())
          (set! gate-effect-count 0))
         (else
          (ensure (and gate-phase (string=? gate-phase phase))
                  "fixture validator phase identity drift")
          (ensure (equal? gate-guards expected-prior)
                  "fixture validator order drift before ~a: ~a"
                  key phase)))
        (when (eq? key 'journal)
          ;; Authentication and automaton validation happen on every gate, not
          ;; merely when the engine first selects an action.
          (journal-history!))
        (when (eq? key 'session)
          (ensure (and session-active?
                       (= opened 1)
                       (zero? closed))
                  "fixture root session is not the one active session"))
        (when (eq? key 'quiescence)
          (ensure (and (not effect-active?)
                       (zero? gate-effect-count))
                  "fixture was not quiescent before its phase effect"))
        (guard-record! key phase)))
    (define backend
      (sk:make-root-backend
       #:name "d4a-in-memory-fixture"
       #:open
       (lambda ()
         (ensure (and (zero? opened) (not session-active?))
                 "fixture backend attempted a second session")
         (set! opened 1)
         (set! session-active? #t)
         (record! '(control session-open))
         'd4a-one-session)
       #:close
       (lambda (token)
         (ensure (and (eq? token 'd4a-one-session)
                      session-active?
                      (= opened 1)
                      (zero? closed))
                 "fixture backend closed another or inactive session")
         (set! session-active? #f)
         (set! closed 1)
         (record! '(control session-close)))
       #:add-temp-root!
       (lambda (_token target)
         (effect!
          `(temporary-root ,target)
          (lambda ()
            (ensure (member target valid)
                    "temporary-root target is outside the manifest")
            (set! temporary (delete-duplicates (cons target temporary)))
            (set! live (delete-duplicates (cons target live)))
            #t)))
       #:direct-root-target
       (lambda (_token root)
         (note-root-guard!)
         (lookup direct root))
       #:registered-root-target
       (lambda (_token root)
         (note-root-guard!)
         (lookup registered root))
       #:direct-roots
       (lambda (_token _namespace)
         (note-root-guard!)
         (enumerate direct))
       #:registered-roots
       (lambda (_token _namespace)
         (note-root-guard!)
         (enumerate registered))
       #:namespace-state
       (lambda (_token _namespace)
         (note-root-guard!)
         (if namespace? 'directory 'absent))
       #:create-namespace!
       (lambda (_token _namespace)
         (effect!
          '(create-namespace)
          (lambda ()
            (ensure (not namespace?)
                    "fixture namespace already exists")
            (set! namespace? #t)
            #t)))
       #:remove-namespace!
       (lambda (_token _namespace)
         (effect!
          '(remove-namespace)
          (lambda ()
            (ensure (and namespace?
                         (null? (enumerate direct))
                         (null? (enumerate registered)))
                    "fixture namespace is not exactly empty")
            (set! namespace? #f)
            #t)))
       #:namespace-empty?
       (lambda (_token _namespace)
         (note-root-guard!)
         (and (null? (enumerate direct))
              (null? (enumerate registered))))
       #:create-direct-root!
       (lambda (_token root target)
         (effect!
          `(create-root ,root ,target)
          (lambda ()
            (ensure (and (member (list root target) all-tuples)
                         (not (lookup direct root))
                         (not (lookup registered root)))
                    "fixture direct root is foreign or already present")
            (when (immediate-child? namespace root)
              (ensure namespace?
                      "fixture managed root has no namespace"))
            (set! direct (acons root target direct))
            #t)))
       #:remove-direct-root!
       (lambda (_token root target)
         (effect!
          `(remove-root ,root ,target)
          (lambda ()
            (ensure (and (equal? (lookup direct root) target)
                         (equal? (lookup registered root) target))
                    "fixture direct root removal tuple drift")
            (set! direct (alist-delete root direct))
            (set! registered (alist-delete root registered))
            #t)))
       #:valid-path?
       (lambda (_token target)
         (note-root-guard!)
         (and (member target valid) #t))
       #:live-path?
       (lambda (_token target)
         (note-root-guard!)
         (and (member target live) #t))
       #:sync-parent!
       (lambda (_token root)
         (effect!
          `(sync-root-parent ,root)
          (lambda ()
            (let ((target (lookup direct root)))
              (if target
                  (set! registered
                        (acons root target (alist-delete root registered)))
                  (set! registered (alist-delete root registered))))
            #t)))))
    (define effects
      `((call-with-locks
         . ,(lambda (actual-state thunk)
              (assert-state! actual-state)
              (ensure (and (procedure? thunk)
                           (not gate-phase)
                           session-active?)
                      "fixture lock scope has an invalid boundary")
              (set! lock-scopes (+ lock-scopes 1))
              (record! '(control locks-acquire))
              (let ((calls 0))
                (let ((result
                       (begin
                         (set! calls (+ calls 1))
                         (thunk))))
                  (ensure (= calls 1)
                          "fixture lock continuation count drift")
                  (ensure (eq? result 'complete)
                          "fixture lock continuation result drift")
                  (record! '(control locks-release))
                  result))))
        (journal-history
         . ,(lambda (actual-state)
              (assert-state! actual-state)
              (journal-history!)))
        (append-journal!
         . ,(lambda (actual-state event subject)
              (assert-state! actual-state)
              (effect!
               `(append-journal ,event ,subject)
               (lambda ()
                 (let* ((before (journal-history!))
                        (successor (list event subject))
                        (updated
                         (if (null? before)
                             (begin
                               (ensure
                                (equal? successor '("BEGIN" "-"))
                                "only BEGIN may create the fixture journal")
                               (sk:render-journal
                                manifest (list successor)))
                             (sk:append-journal-event
                              manifest journal successor))))
                   (set! journal updated)
                   (ensure
                    (equal?
                     (sk:parse-journal manifest journal)
                     (append before (list successor)))
                    "fixture journal append did not persist exactly")
                   #t)))))
        (old-grub-backup!
         . ,(lambda (actual-state)
              (assert-state! actual-state)
              (effect!
               '(old-grub-backup)
               (lambda ()
                 (ensure (and (not backup?) (eq? grub 'old))
                         "fixture old-GRUB backup prestate drift")
                 (set! backup? #t)
                 #t))))
        (grub!
         . ,(lambda (actual-state direction)
              (assert-state! actual-state)
              (effect!
               `(grub ,direction)
               (lambda ()
                 (case direction
                   ((forward)
                    (ensure (eq? grub 'old)
                            "fixture forward GRUB prestate drift")
                    (set! grub 'new))
                   ((rollback)
                    (ensure (eq? grub 'new)
                            "fixture rollback GRUB prestate drift")
                    (set! grub 'old))
                   (else (%fail "unknown fixture GRUB direction")))
                 #t))))
        (bootcfg!
         . ,(lambda (actual-state direction)
              (assert-state! actual-state)
              (effect!
               `(bootcfg ,direction)
               (lambda ()
                 (case direction
                   ((forward)
                    (ensure (eq? bootcfg 'old)
                            "fixture forward bootcfg prestate drift")
                    (set! bootcfg 'new))
                   ((rollback)
                    (ensure (eq? bootcfg 'new)
                            "fixture rollback bootcfg prestate drift")
                    (set! bootcfg 'old))
                   (else (%fail "unknown fixture bootcfg direction")))
                 #t))))
        (link!
         . ,(lambda (actual-state operation subject)
              (assert-state! actual-state)
              (effect!
               `(link ,operation ,subject)
               (lambda ()
                 (let ((before (and=> (assoc subject links) cdr)))
                   (case operation
                     ((exclude)
                      (ensure (eq? before 'present)
                              "fixture link exclusion prestate drift")
                      (set-link! subject 'excluded))
                     ((discard)
                      (ensure (eq? before 'excluded)
                              "fixture link discard prestate drift")
                      (set-link! subject 'discarded))
                     ((restore)
                      (ensure before "fixture link restore subject is absent")
                      (set-link! subject 'present))
                     (else (%fail "unknown fixture link operation"))))
                 #t))))
        (verify!
         . ,(lambda (actual-state checkpoint)
              (assert-state! actual-state)
              (effect!
               `(verify ,checkpoint)
               (lambda ()
                 (case checkpoint
                   ((roots-ready) #t)
                   ((links-staged)
                    (ensure (all-links? 'excluded)
                            "fixture staged-link verification drift"))
                   ((links-committed)
                    (ensure (all-links? 'discarded)
                            "fixture committed-link verification drift"))
                   ((forward-postflight)
                    (ensure (and (eq? grub 'new)
                                 (eq? bootcfg 'new)
                                 (all-links? 'discarded))
                            "fixture forward postflight drift"))
                   ((links-restored)
                    (ensure (all-links? 'present)
                            "fixture restored-link verification drift"))
                   ((rollback-prestate)
                    (ensure (and (eq? grub 'old)
                                 (eq? bootcfg 'old)
                                 (all-links? 'present))
                            "fixture rollback prestate drift"))
                   (else (%fail "unknown fixture verification checkpoint")))
                 #t))))
        (terminal-recorded?
         . ,(lambda (actual-state terminal)
              (assert-state! actual-state)
              (let ((history (journal-history!)))
                (and (pair? history)
                     (string=? (car (last history)) terminal)))))
        (postflight-complete?
         . ,(lambda (actual-state terminal)
              (assert-state! actual-state)
              (and postflight-terminal
                   (string=? postflight-terminal terminal))))
        (postflight!
         . ,(lambda (actual-state terminal)
              (assert-state! actual-state)
              (effect!
               `(terminal-postflight ,terminal)
               (lambda ()
                 (ensure (and (member terminal '("COMPLETE" "ROLLED-BACK"))
                              (not postflight-terminal))
                         "fixture terminal postflight prestate drift")
                 (set! postflight-terminal terminal)
                 #t))))))
    (define validators
      `((protected . ,(phase-validator 'protected '()))
        (journal . ,(phase-validator 'journal '(protected)))
        (session . ,(phase-validator
                     'session '(protected journal roots)))
        (quiescence . ,(phase-validator
                        'quiescence
                        '(protected journal roots session)))))
    (define (stop label)
      (ensure (and gate-phase
                   (string=? label
                             (string-append "after-" gate-phase)))
              "fixture stop label differs from its active phase: ~a"
              label)
      (ensure (= gate-effect-count 1)
              "fixture stop reached without one exact effect: ~a"
              gate-phase)
      (record! `(stop ,gate-phase))
      (set! gate-phase #f)
      (set! gate-guards '())
      (set! gate-effect-count 0)
      #t)
    `((backend . ,backend)
      (effects . ,effects)
      (validators . ,validators)
      (stop . ,stop)
      (state . ,state)
      (timeline . ,(lambda () timeline))
      (executed-phases . ,(lambda () executed-phases))
      (history . ,journal-history!)
      (direct . ,(lambda () direct))
      (registered . ,(lambda () registered))
      (namespace? . ,(lambda () namespace?))
      (opened . ,(lambda () opened))
      (closed . ,(lambda () closed))
      (lock-scopes . ,(lambda () lock-scopes))
      (gate-active? . ,(lambda () (and gate-phase #t)))
      (guard-count
       . ,(lambda ()
            (count
             (lambda (item)
               (and (pair? item) (eq? (car item) 'guard)))
             timeline)))
      (effect-count
       . ,(lambda ()
            (count
             (lambda (item)
               (and (pair? item) (eq? (car item) 'effect)))
             timeline))))))

(define (world-ref world key)
  (alist-value world key))

(define (sk:run-fixture-runtime! runtime action)
  "Run ACTION through the real D4a phase engine and return a closed result.

ACTION is exactly `fixture-apply' or `fixture-recover'.  The adapter opens one
in-memory root session, uses no filesystem path, and consumes RUNTIME even when
execution fails.  A consumed runtime cannot be mistaken for a restartable
store session."
  (ensure (sk:fixture-runtime? runtime)
          "value is not a fixture runtime")
  (ensure (member action %actions)
          "unsupported fixture-runtime action: ~s" action)
  (ensure (not (fixture-runtime-used? runtime))
          "fixture runtime has already been consumed")
  (set-fixture-runtime-used?! runtime #t)
  (let* ((manifest
          (sk:assert-phase-engine-manifest
           (fixture-runtime-manifest runtime)))
         (world
          (make-world
           manifest
           action
           (fixture-runtime-initial-journal runtime)
           (lambda (timeline)
             (set-fixture-runtime-timeline! runtime timeline))))
         (engine-action
          (if (string=? action "fixture-apply") "forward" "recover"))
         (engine-result
          (sk:call-with-root-session
           (world-ref world 'backend)
           (lambda (session)
             (sk:run-phase-engine!
              session manifest engine-action
              (world-ref world 'state)
              (world-ref world 'effects)
              (world-ref world 'validators)
              (world-ref world 'stop)))))
         (history ((world-ref world 'history)))
         (terminal (and (pair? history) (car (last history))))
         (expected-terminal
          (if (string=? action "fixture-apply")
              "COMPLETE"
              "ROLLED-BACK"))
         (timeline ((world-ref world 'timeline)))
         (executed ((world-ref world 'executed-phases)))
         (guards ((world-ref world 'guard-count)))
         (effects ((world-ref world 'effect-count))))
    (ensure (eq? engine-result 'complete)
            "fixture phase engine did not return complete")
    (ensure (and terminal (string=? terminal expected-terminal))
            "fixture terminal differs: expected ~a, got ~s"
            expected-terminal terminal)
    (ensure (not ((world-ref world 'gate-active?)))
            "fixture phase gate remained active")
    (ensure (= guards (* (length %guard-order) effects))
            "fixture guard/effect cardinality differs")
    (ensure (= effects (length executed))
            "fixture executed-phase/effect cardinality differs")
    (ensure (and (null? ((world-ref world 'direct)))
                 (null? ((world-ref world 'registered)))
                 (not ((world-ref world 'namespace?))))
            "fixture terminal root state is not empty")
    (ensure (and (= ((world-ref world 'opened)) 1)
                 (= ((world-ref world 'closed)) 1)
                 (= ((world-ref world 'lock-scopes)) 1))
            "fixture one-session or lock-scope contract differs")
    (assert-result
     (make-result
      manifest action "COMPLETE" terminal
      (sk:phase-engine-required-phases manifest)
      executed history guards effects
      ((world-ref world 'opened))
      ((world-ref world 'closed))
      ((world-ref world 'lock-scopes))
      timeline))))
