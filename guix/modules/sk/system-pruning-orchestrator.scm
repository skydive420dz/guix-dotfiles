;;; Pure P5.2b-D4a root and phase orchestration.

(define-module (sk system-pruning-orchestrator)
  #:use-module (sk system-pruning-boundary)
  #:use-module (sk system-pruning-root-backend)
  #:use-module (srfi srfi-1)
  #:export (sk:orchestrator-root-tuples
            sk:orchestrator-recovery-root-tuples
            sk:orchestrator-root-namespace
            sk:assert-orchestrator-root-set
            sk:bootstrap-orchestrator-program-root!
            sk:bootstrap-orchestrator-recovery-roots!
            sk:pin-orchestrator-remaining-roots!
            sk:call-with-orchestrator-phase
            sk:cleanup-orchestrator-roots!))

(define %error-key 'sk-system-pruning-orchestrator)
(define %phase-validator-keys '(protected journal session quiescence))
(define %root-state-keys
  '(program-direct program-registered namespace direct-roots registered-roots))

(define (%fail format-string . arguments)
  (throw %error-key (apply format #f format-string arguments)))

(define (ensure condition format-string . arguments)
  (unless condition
    (apply %fail format-string arguments)))

(define (alist-value alist key)
  (let ((entry (assq key alist)))
    (ensure entry "missing orchestrator record: ~s" key)
    (cdr entry)))

(define (manifest-sha manifest)
  (alist-value (sk:assert-boundary-manifest manifest) 'manifest-sha))

(define (program-tuple manifest)
  (let ((record
         (alist-value
          (sk:assert-boundary-manifest manifest)
          'program-root)))
    (list (car record) (cadr record))))

(define (sk:orchestrator-root-namespace manifest)
  "Return MANIFEST's one managed candidate/bootcfg root namespace."
  (string-append
   "/var/guix/gcroots/p52b-system-prune/"
   (manifest-sha manifest)))

(define (recovery-tuple manifest record)
  (list
   (string-append
    (sk:orchestrator-root-namespace manifest)
    "/"
    (cadr record))
   (list-ref record 3)))

(define (sk:orchestrator-recovery-root-tuples manifest)
  "Return the exact ordered candidate/bootcfg tuples for MANIFEST."
  (map (lambda (record) (recovery-tuple manifest record))
       (sk:boundary-roots manifest)))

(define (sk:orchestrator-root-tuples manifest)
  "Return the exact program-first direct-root tuples for MANIFEST."
  (cons
   (program-tuple manifest)
   (sk:orchestrator-recovery-root-tuples manifest)))

(define (sorted-tuples tuples)
  (sort (map (lambda (tuple) (list (car tuple) (cadr tuple))) tuples)
        (lambda (left right) (string<? (car left) (car right)))))

(define (same-tuples? left right)
  (equal? (sorted-tuples left) (sorted-tuples right)))

(define (assert-target session tuple)
  (let ((target (cadr tuple)))
    (ensure (sk:root-session-valid-path? session target)
            "recovery-root target is invalid: ~a"
            target)
    (ensure (sk:root-session-live-path? session target)
            "recovery-root target is not live: ~a"
            target)
    #t))

(define (root-state program-direct program-registered namespace
                    direct-roots registered-roots)
  `((program-direct . ,program-direct)
    (program-registered . ,program-registered)
    (namespace . ,namespace)
    (direct-roots . ,direct-roots)
    (registered-roots . ,registered-roots)))

(define (complete-root-state manifest)
  (let ((program (program-tuple manifest))
        (recovery (sk:orchestrator-recovery-root-tuples manifest)))
    (root-state program program 'directory recovery recovery)))

(define (assert-root-state-shape manifest expected)
  (ensure (and (list? expected)
               (equal? (map car expected) %root-state-keys))
          "orchestrator expected-root state differs from the closed shape")
  (let* ((program (program-tuple manifest))
         (recovery (sk:orchestrator-recovery-root-tuples manifest))
         (program-direct (alist-value expected 'program-direct))
         (program-registered (alist-value expected 'program-registered))
         (namespace (alist-value expected 'namespace))
         (direct (alist-value expected 'direct-roots))
         (registered (alist-value expected 'registered-roots)))
    (ensure (or (not program-direct) (equal? program-direct program))
            "expected direct program root is not absent or exact")
    (ensure (or (not program-registered)
                (equal? program-registered program))
            "expected registered program root is not absent or exact")
    (ensure (memq namespace '(absent directory))
            "expected namespace state is invalid")
    (ensure (and (list? direct) (list? registered))
            "expected managed roots are not lists")
    (for-each
     (lambda (tuple)
       (ensure (member tuple recovery)
               "expected direct root is outside the manifest: ~s"
               tuple))
     direct)
    (for-each
     (lambda (tuple)
       (ensure (member tuple recovery)
               "expected registered root is outside the manifest: ~s"
               tuple))
     registered)
    (ensure (= (length direct) (length (delete-duplicates (map car direct))))
            "expected direct roots contain duplicates")
    (ensure (= (length registered)
               (length (delete-duplicates (map car registered))))
            "expected registered roots contain duplicates")
    expected))

(define* (sk:assert-orchestrator-root-set
          session manifest #:optional (expected #f))
  "Prove EXPECTED is the complete direct/registered managed-root state.

Enumeration is compared as an exact set, so an extra direct root or daemon
registration fails even when every manifest tuple is present."
  (let* ((expected
          (assert-root-state-shape
           manifest
           (or expected (complete-root-state manifest))))
         (program (program-tuple manifest))
         (program-root (car program))
         (program-target (cadr program))
         (expected-program-direct
          (alist-value expected 'program-direct))
         (expected-program-registered
          (alist-value expected 'program-registered))
         (namespace (sk:orchestrator-root-namespace manifest))
         (expected-namespace (alist-value expected 'namespace))
         (expected-direct (alist-value expected 'direct-roots))
         (expected-registered (alist-value expected 'registered-roots))
         (actual-program-direct
          (sk:root-session-direct-root-target session program-root))
         (actual-program-registered
          (sk:root-session-registered-root-target session program-root))
         (actual-namespace
          (sk:root-session-namespace-state session namespace))
         (actual-direct
          (if (eq? actual-namespace 'directory)
              (sk:root-session-direct-roots session namespace)
              '()))
         (actual-registered
          (if (eq? actual-namespace 'directory)
              (sk:root-session-registered-roots session namespace)
              '())))
    (ensure (equal? actual-program-direct
                    (and expected-program-direct program-target))
            "direct program root is absent or retargeted")
    (ensure (equal? actual-program-registered
                    (and expected-program-registered program-target))
            "registered program root is absent or retargeted")
    (ensure (eq? actual-namespace expected-namespace)
            "managed recovery-root namespace state differs")
    (ensure (same-tuples? actual-direct expected-direct)
            "direct managed-root set differs or contains extras")
    (ensure (same-tuples? actual-registered expected-registered)
            "registered managed-root set differs or contains extras")
    (when expected-program-direct (assert-target session program))
    (for-each (lambda (tuple) (assert-target session tuple))
              expected-direct)
    #t))

(define (call-stop stop label)
  (ensure (procedure? stop) "orchestrator stop callback is not a procedure")
  (let ((result (stop label)))
    (ensure (eq? result #t)
            "orchestrator stop callback refused boundary: ~a"
            label)))

(define (assert-phase-validators validators)
  (ensure (and (list? validators)
               (equal? (map car validators) %phase-validator-keys))
          "orchestrator phase validators differ from the closed set")
  (for-each
   (lambda (entry)
     (ensure (procedure? (cdr entry))
             "orchestrator phase validator is not a procedure: ~s"
             (car entry)))
   validators))

(define* (sk:call-with-orchestrator-phase
          session manifest phase state validators thunk
          #:optional (expected-root-state #f))
  "Run THUNK only through the central boundary gate and exact root proof.

EXPECTED-ROOT-STATE defaults to the complete program and managed-root set.
Bootstrap and cleanup pass explicit construction-prefix states."
  (assert-phase-validators validators)
  (let ((expected
         (or expected-root-state (complete-root-state manifest))))
    (sk:call-with-pre-phase-gate
     manifest
     phase
     state
     `((protected . ,(alist-value validators 'protected))
       (journal . ,(alist-value validators 'journal))
       (roots
        . ,(lambda (_manifest _phase _state)
             (sk:assert-orchestrator-root-set
              session manifest expected)))
       (session . ,(alist-value validators 'session))
       (quiescence . ,(alist-value validators 'quiescence)))
     thunk)))

(define (call-effect session manifest phase state validators expected thunk stop)
  (sk:call-with-orchestrator-phase
   session manifest phase state validators thunk expected)
  (call-stop stop (string-append "after-" phase)))

(define (observed-program-state session manifest namespace-state
                                direct registered)
  (let* ((program (program-tuple manifest))
         (root (car program))
         (target (cadr program))
         (actual-direct
          (sk:root-session-direct-root-target session root))
         (actual-registered
          (sk:root-session-registered-root-target session root)))
    (ensure (or (not actual-direct) (string=? actual-direct target))
            "direct program root is retargeted")
    (ensure (or (not actual-registered)
                (string=? actual-registered target))
            "registered program root is retargeted")
    (ensure (or actual-direct (not actual-registered))
            "program root is registered without a direct root")
    (root-state
     (and actual-direct program)
     (and actual-registered program)
     namespace-state
     direct
     registered)))

(define (assert-program-bootstrap-recovery-state manifest namespace
                                                 direct registered)
  (let ((expected (sk:orchestrator-recovery-root-tuples manifest)))
    (cond
     ((eq? namespace 'absent)
      (ensure (and (null? direct) (null? registered))
              "managed roots exist without their namespace"))
     ((and (same-tuples? direct registered)
           (or (prefix-set? direct expected)
               (suffix-set? direct expected)))
      #t)
     ((and (prefix-set? direct expected)
           (prefix-set? registered expected)
           (= (length direct) (+ (length registered) 1))
           (same-tuples? registered
                         (take expected (length registered))))
      #t)
     (else
      (%fail "managed roots are not a legal bootstrap or cleanup prefix")))))

(define (sk:bootstrap-orchestrator-program-root!
         session manifest state validators stop)
  "Create or reconcile only the direct program root, before locks and roots."
  (call-with-values
      (lambda () (observed-recovery-state session manifest))
    (lambda (namespace direct registered)
      (assert-program-bootstrap-recovery-state
       manifest namespace direct registered)
      (let* ((program (program-tuple manifest))
             (root (car program))
             (target (cadr program))
             (observed
              (observed-program-state
               session manifest namespace direct registered)))
    ;; A durable root does not replace the temporary pin required by this
    ;; newly opened store session.  Reentry therefore pins the program target
    ;; even when both direct and daemon views are already exact.
    (call-effect
     session manifest "temporary-root:program-root"
     state validators observed
     (lambda () (sk:root-session-add-temp-root! session target))
     stop)
    (cond
     ((not (alist-value observed 'program-direct))
      (ensure (and (eq? namespace 'absent)
                   (null? direct)
                   (null? registered))
              "persistent recovery state exists without the program root")
      (call-effect
       session manifest "create-root:program-root"
       state validators observed
       (lambda ()
         (sk:root-session-create-direct-root! session root target))
       stop))
     (else #t))
    (let ((before-sync
           (observed-program-state
            session manifest namespace direct registered)))
      (unless (alist-value before-sync 'program-registered)
        (call-effect
         session manifest "sync-root:program-root" state validators before-sync
         (lambda () (sk:root-session-sync-parent! session root))
         stop)))
    (let ((complete
           (root-state program program namespace direct registered)))
      (sk:assert-orchestrator-root-set session manifest complete)
      program)))))

(define (prefix-set? prefix whole)
  (and (<= (length prefix) (length whole))
       (same-tuples? prefix (take whole (length prefix)))))

(define (observed-recovery-state session manifest)
  (let* ((namespace (sk:orchestrator-root-namespace manifest))
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
    (values namespace-state direct registered)))

(define (assert-bootstrap-prefix expected direct registered)
  (ensure (prefix-set? direct expected)
          "direct managed roots are not an ordered bootstrap prefix")
  (ensure (prefix-set? registered expected)
          "registered managed roots are not an ordered bootstrap prefix")
  (ensure (or (= (length direct) (length registered))
              (= (length direct) (+ (length registered) 1)))
          "direct and registered bootstrap prefixes diverge")
  (ensure (same-tuples? registered
                        (take expected (length registered)))
          "registered bootstrap prefix is not a direct-root prefix")
  #t)

(define (current-root-state session manifest namespace direct registered)
  (let ((program (program-tuple manifest)))
    (root-state program program namespace direct registered)))

(define (sk:bootstrap-orchestrator-recovery-roots!
         session manifest state validators stop)
  "Create/reconcile the namespace and ordered candidate/bootcfg roots.

The program root must already be exact.  Existing state may only be the one
ordered direct/registration construction prefix."
  (let* ((namespace (sk:orchestrator-root-namespace manifest))
         (expected (sk:orchestrator-recovery-root-tuples manifest)))
    (call-with-values
        (lambda () (observed-recovery-state session manifest))
      (lambda (namespace-state direct registered)
        (when (eq? namespace-state 'absent)
          (let ((before
                 (current-root-state
                  session manifest 'absent '() '())))
            (call-effect
             session manifest "create-root-namespace" state validators before
             (lambda ()
               (sk:root-session-create-namespace! session namespace))
             stop)))))
    (call-with-values
        (lambda () (observed-recovery-state session manifest))
      (lambda (namespace-state direct registered)
        (ensure (eq? namespace-state 'directory)
                "managed recovery-root namespace is absent after creation")
        (assert-bootstrap-prefix expected direct registered)
        (let ((before
               (current-root-state
                session manifest namespace-state direct registered)))
          (for-each
           (lambda (tuple)
             (let ((name (basename (car tuple))))
               (call-effect
                session manifest
                (string-append "temporary-root:" name)
                state validators before
                (lambda ()
                  (sk:root-session-add-temp-root! session (cadr tuple)))
                stop)))
           (take expected (length direct))))))
    (let loop ()
      (call-with-values
          (lambda () (observed-recovery-state session manifest))
        (lambda (namespace-state direct registered)
          (ensure (eq? namespace-state 'directory)
                  "managed recovery-root namespace is absent after creation")
          (assert-bootstrap-prefix expected direct registered)
          (let ((before
                 (current-root-state
                  session manifest namespace-state direct registered)))
            (cond
             ((< (length registered) (length direct))
              (let* ((tuple (list-ref expected (length registered)))
                     (name (basename (car tuple))))
                (call-effect
                 session manifest
                 (string-append "sync-root:" name)
                 state validators before
                 (lambda ()
                   (sk:root-session-sync-parent! session (car tuple)))
                 stop)
                (loop)))
             ((< (length direct) (length expected))
              (let* ((tuple (list-ref expected (length direct)))
                     (name (basename (car tuple))))
                (call-effect
                 session manifest
                 (string-append "temporary-root:" name)
                 state validators before
                 (lambda ()
                   (sk:root-session-add-temp-root! session (cadr tuple)))
                 stop)
                (call-effect
                 session manifest
                 (string-append "create-root:" name)
                 state validators before
                 (lambda ()
                   (sk:root-session-create-direct-root!
                    session (car tuple) (cadr tuple)))
                 stop)
                (loop)))
             (else
              (let ((complete (complete-root-state manifest)))
                (sk:assert-orchestrator-root-set
                 session manifest complete)
                expected)))))))))

(define (sk:pin-orchestrator-remaining-roots!
         session manifest state validators stop)
  "Temporarily pin only the exact candidate/bootcfg cleanup suffix.

This is the recovery counterpart to bootstrap: it never recreates an already
removed root.  Extras, a missing middle tuple, or direct/registration drift
fail before the first temporary-root effect."
  (let ((expected (sk:orchestrator-recovery-root-tuples manifest)))
    (call-with-values
        (lambda () (observed-recovery-state session manifest))
      (lambda (namespace direct registered)
        (let ((remaining
               (assert-cleanup-prefix expected direct registered)))
          (ensure (or (and (eq? namespace 'absent) (null? remaining))
                      (eq? namespace 'directory))
                  "remaining managed roots have no exact namespace")
          (let ((current
                 (current-root-state
                  session manifest namespace direct registered)))
            (for-each
             (lambda (tuple)
               (let ((name (basename (car tuple))))
                 (call-effect
                  session manifest
                  (string-append "temporary-root:" name)
                  state validators current
                  (lambda ()
                    (sk:root-session-add-temp-root! session (cadr tuple)))
                  stop)))
             remaining))
          remaining)))))

(define (suffix-set? suffix whole)
  (and (<= (length suffix) (length whole))
       (same-tuples?
        suffix
        (drop whole (- (length whole) (length suffix))))))

(define (assert-cleanup-prefix expected direct registered)
  (ensure (same-tuples? direct registered)
          "direct and registered cleanup sets differ")
  (ensure (suffix-set? direct expected)
          "managed roots are not an exact ordered cleanup suffix")
  (drop expected (- (length expected) (length direct))))

(define (exact-boolean procedure label terminal)
  (ensure (procedure? procedure) "~a callback is not a procedure" label)
  (let ((result (procedure terminal)))
    (ensure (boolean? result) "~a callback returned a non-boolean" label)
    result))

(define (cleanup-event-names terminal)
  (if (string=? terminal "COMPLETE")
      (values "ROOT-REMOVE-INTENT" "ROOT-REMOVE-DONE")
      (values "ROLLBACK-ROOT-REMOVE-INTENT"
              "ROLLBACK-ROOT-REMOVE-DONE")))

(define (observed-root-event? root-event-recorded? event subject)
  (ensure (procedure? root-event-recorded?)
          "root-event observation callback is not a procedure")
  (let ((result (root-event-recorded? event subject)))
    (ensure (boolean? result)
            "root-event observation callback returned a non-boolean")
    result))

(define (remove-program-root!
         session manifest state validators terminal-recorded?
         postflight-complete? stop)
  (let* ((program (program-tuple manifest))
         (root (car program))
         (target (cadr program))
         (before
          (observed-program-state session manifest 'absent '() '()))
         (direct (alist-value before 'program-direct))
         (registered (alist-value before 'program-registered)))
    (ensure (and (exact-boolean terminal-recorded?
                                "terminal-observation" "-")
                 (exact-boolean postflight-complete?
                                "postflight-observation" "-"))
            "program root cannot be removed before terminal postflight")
    (cond
     ((and direct registered)
      (call-effect
       session manifest "remove-root:program-root" state validators before
       (lambda ()
         (sk:root-session-remove-direct-root! session root target))
       stop))
     ((or direct registered)
      (%fail "program root removal state is partial or retargeted"))
     (else #t))
    (let ((removed
           (observed-program-state session manifest 'absent '() '())))
      (call-effect
       session manifest "sync-root-removal:program-root"
       state validators removed
       (lambda () (sk:root-session-sync-parent! session root))
       stop))
    (sk:assert-orchestrator-root-set
     session manifest (root-state #f #f 'absent '() '()))
    'complete))

(define (sk:cleanup-orchestrator-roots!
         session manifest terminal state validators
         root-event-recorded? append-root-event-callback
         terminal-recorded? append-terminal!
         postflight-complete? postflight! stop)
  "Reconcile an exact cleanup prefix and remove the program root last.

Candidate/bootcfg removals, namespace removal, terminal append, terminal
postflight, and the final program-root removal are separate gated effects.
TERMINAL-RECORDED? and POSTFLIGHT-COMPLETE? make every completed prefix
restartable without replaying an already durable semantic effect."
  (ensure (member terminal '("COMPLETE" "ROLLED-BACK"))
          "invalid orchestrator terminal event: ~s"
          terminal)
  (for-each
   (lambda (binding)
     (ensure (procedure? (cdr binding))
             "cleanup callback is not a procedure: ~a"
             (car binding)))
   `((terminal-recorded? . ,terminal-recorded?)
     (root-event-recorded? . ,root-event-recorded?)
     (append-root-event! . ,append-root-event-callback)
     (append-terminal! . ,append-terminal!)
     (postflight-complete? . ,postflight-complete?)
     (postflight! . ,postflight!)
     (stop . ,stop)))
  (let* ((namespace (sk:orchestrator-root-namespace manifest))
         (expected (sk:orchestrator-recovery-root-tuples manifest)))
    (sk:pin-orchestrator-remaining-roots!
     session manifest state validators stop)
    (call-with-values
        (lambda () (cleanup-event-names terminal))
      (lambda (intent-event done-event)
        (let remove-loop ()
      (call-with-values
          (lambda () (observed-recovery-state session manifest))
        (lambda (namespace-state direct registered)
          (let* ((remaining
                  (assert-cleanup-prefix expected direct registered))
                 (removed-count
                  (- (length expected) (length remaining)))
                 (removed (take expected removed-count))
                 (current
                  (current-root-state
                   session manifest namespace-state direct registered)))
          (for-each
           (lambda (tuple)
             (let ((name (basename (car tuple))))
               (ensure
                (observed-root-event?
                 root-event-recorded? intent-event name)
                "removed root has no durable removal intent: ~a"
                name)
               (ensure
                (observed-root-event?
                 root-event-recorded? done-event name)
                "an older removed root has no durable DONE event: ~a"
                name)))
           (drop-right removed (if (pair? removed) 1 0)))
          (when (pair? removed)
            (let* ((previous (last removed))
                   (name (basename (car previous))))
              (ensure
               (observed-root-event?
                root-event-recorded? intent-event name)
               "removed root has no durable removal intent: ~a"
               name)
              (unless (observed-root-event?
                       root-event-recorded? done-event name)
                (call-effect
                 session manifest
                 (string-append "sync-root-removal:" name)
                 state validators current
                 (lambda ()
                   (sk:root-session-sync-parent! session (car previous)))
                 stop)
                (call-effect
                 session manifest
                 (string-append "append-root-remove-done:" name)
                 state validators current
                 (lambda ()
                   (ensure
                    (eq? (append-root-event-callback
                          done-event name)
                         #t)
                    "root DONE append did not return exact success"))
                 stop)
                (ensure
                 (observed-root-event?
                  root-event-recorded? done-event name)
                 "root DONE append did not become observable: ~a"
                 name))))
          (cond
           ((pair? remaining)
            (let* ((tuple (car remaining))
                   (name (basename (car tuple)))
                   (before
                    (current-root-state
                     session manifest namespace-state direct registered)))
              (ensure
               (not (observed-root-event?
                     root-event-recorded? done-event name))
               "present root already has a DONE removal event: ~a"
               name)
              (unless (observed-root-event?
                       root-event-recorded? intent-event name)
                (call-effect
                 session manifest
                 (string-append "append-root-remove-intent:" name)
                 state validators before
                 (lambda ()
                   (ensure
                    (eq? (append-root-event-callback
                          intent-event name)
                         #t)
                    "root intent append did not return exact success"))
                 stop)
                (ensure
                 (observed-root-event?
                  root-event-recorded? intent-event name)
                 "root intent append did not become observable: ~a"
                 name))
              (call-effect
               session manifest
               (string-append "remove-root:" name)
               state validators before
               (lambda ()
                 (sk:root-session-remove-direct-root!
                  session (car tuple) (cadr tuple)))
               stop)
              (remove-loop)))
           ((eq? namespace-state 'directory)
            (ensure (sk:root-session-namespace-empty? session namespace)
                    "managed root namespace contains a foreign entry")
            (let ((before
                   (current-root-state
                    session manifest namespace-state '() '())))
              (call-effect
               session manifest "remove-root-namespace"
               state validators before
               (lambda ()
                 (sk:root-session-remove-namespace! session namespace))
               stop)
              (remove-loop)))
           (else #t))))))))
    (let ((empty
           (current-root-state session manifest 'absent '() '())))
      (unless (exact-boolean terminal-recorded?
                             "terminal-observation" terminal)
        (call-effect
         session manifest
         (string-append "append-terminal:" terminal)
         state validators empty
         (lambda ()
           (ensure (eq? (append-terminal! terminal) #t)
                   "terminal append callback did not return exact success"))
         stop)
        (ensure (exact-boolean terminal-recorded?
                               "terminal-observation" terminal)
                "terminal callback did not make the event observable"))
      (unless (exact-boolean postflight-complete?
                             "postflight-observation" terminal)
        (call-effect
         session manifest
         (string-append "terminal-postflight:" terminal)
         state validators empty
         (lambda ()
           (ensure (eq? (postflight! terminal) #t)
                   "terminal postflight callback did not return exact success"))
         stop)
        (ensure (exact-boolean postflight-complete?
                               "postflight-observation" terminal)
                "postflight callback did not make completion observable")))
    (remove-program-root!
     session manifest state validators
     (lambda (_ignored) (terminal-recorded? terminal))
     (lambda (_ignored) (postflight-complete? terminal))
     stop)))
