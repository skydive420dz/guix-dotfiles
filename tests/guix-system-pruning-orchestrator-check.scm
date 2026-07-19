;;; Deterministic tests for the pure D4a root/phase orchestrator.

(use-modules (sk system-pruning-orchestrator)
             (sk system-pruning-root-backend)
             (srfi srfi-1))

(define %program "guix-system-pruning-orchestrator-check")
(define %sha (make-string 64 #\a))
(define %program-target
  "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system-pruning-loaded.scm")
(define %root-records
  '(("candidate" "candidate-g1" "1"
     "/gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-system")
    ("candidate" "candidate-g2" "2"
     "/gnu/store/cccccccccccccccccccccccccccccccc-system")
    ("bootcfg-old" "old-bootcfg" "-"
     "/gnu/store/dddddddddddddddddddddddddddddddd-grub.cfg")
    ("bootcfg-new" "new-bootcfg" "-"
     "/gnu/store/ffffffffffffffffffffffffffffffff-grub.cfg")))
(define %root-names (map cadr %root-records))
(define %phases
  (append
   '("transaction-effect"
     "temporary-root:program-root"
     "create-root:program-root"
     "sync-root:program-root"
     "create-root-namespace"
     "append-terminal:COMPLETE"
     "terminal-postflight:COMPLETE"
     "append-terminal:ROLLED-BACK"
     "terminal-postflight:ROLLED-BACK"
     "remove-root:program-root"
     "sync-root-removal:program-root")
   (append-map
    (lambda (name)
      (list (string-append "temporary-root:" name)
            (string-append "create-root:" name)
            (string-append "sync-root:" name)
            (string-append "append-root-remove-intent:" name)
            (string-append "remove-root:" name)
            (string-append "sync-root-removal:" name)
            (string-append "append-root-remove-done:" name)))
    %root-names)
   '("remove-root-namespace")))
(define %manifest
  `((schema . "p5.2b-system-prune-boundary/v1")
    (mode . "FIXTURE-ONLY")
    (authorization . "NOT-GRANTED")
    (manifest-sha . ,%sha)
    (program-root
     . (,(string-append
          "/var/guix/gcroots/p52b-system-prune-program-" %sha)
        ,%program-target))
    (roots . ,%root-records)
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

(define (fails? thunk)
  (catch #t
    (lambda () (thunk) #f)
    (lambda _ #t)))

(define (child-of? namespace root)
  (let ((prefix (string-append namespace "/")))
    (and (string-prefix? prefix root)
         (not (string-contains
               (substring root (string-length prefix))
               "/")))))

(define (make-synthetic-backend)
  (let ((events '())
        (namespaces '())
        (foreign '())
        (direct '())
        (registered '())
        (temporary '())
        (valid-state #t)
        (live-state #t)
        (open-state #t)
        (opened 0)
        (closed 0))
    (define (record! event)
      (set! events (cons event events))
      #t)
    (define (enumerate roots namespace)
      (filter-map
       (lambda (entry)
         (and (child-of? namespace (car entry))
              (list (car entry) (cdr entry))))
       roots))
    (define backend
      (sk:make-root-backend
       #:name "orchestrator-synthetic"
       #:open
       (lambda ()
         (and open-state
              (begin
                (set! opened (+ opened 1))
                (record! `(open ,opened))
                opened)))
       #:close
       (lambda (token)
         (set! closed (+ closed 1))
         (record! `(close ,token)))
       #:add-temp-root!
       (lambda (_token target)
         (record! `(temporary ,target))
         (set! temporary (cons target temporary))
         #t)
       #:direct-root-target
       (lambda (_token root)
         (record! `(direct-observe ,root))
         (and=> (assoc root direct) cdr))
       #:registered-root-target
       (lambda (_token root)
         (record! `(registered-observe ,root))
         (and=> (assoc root registered) cdr))
       #:direct-roots
       (lambda (_token namespace)
         (record! `(direct-enumerate ,namespace))
         (enumerate direct namespace))
       #:registered-roots
       (lambda (_token namespace)
         (record! `(registered-enumerate ,namespace))
         (enumerate registered namespace))
       #:namespace-state
       (lambda (_token namespace)
         (record! `(namespace-observe ,namespace))
         (if (member namespace namespaces) 'directory 'absent))
       #:create-namespace!
       (lambda (_token namespace)
         (record! `(namespace-create ,namespace))
         (and (not (member namespace namespaces))
              (begin
                (set! namespaces (cons namespace namespaces))
                #t)))
       #:remove-namespace!
       (lambda (_token namespace)
         (record! `(namespace-remove ,namespace))
         (and (null? (enumerate direct namespace))
              (null? (filter
                      (lambda (path) (child-of? namespace path))
                      foreign))
              (begin
                (set! namespaces (delete namespace namespaces))
                #t)))
       #:namespace-empty?
       (lambda (_token namespace)
         (record! `(namespace-empty ,namespace))
         (and (null? (enumerate direct namespace))
              (null? (filter
                      (lambda (path) (child-of? namespace path))
                      foreign))))
       #:create-direct-root!
       (lambda (_token root target)
         (record! `(create ,root ,target))
         (and (not (assoc root direct))
              (begin
                (set! direct (acons root target direct))
                #t)))
       #:remove-direct-root!
       (lambda (_token root target)
         (record! `(remove ,root ,target))
         (let ((entry (assoc root direct)))
           (and entry
                (string=? (cdr entry) target)
                (begin
                  (set! direct (alist-delete root direct))
                  (set! registered (alist-delete root registered))
                  #t))))
       #:valid-path?
       (lambda (_token target)
         (record! `(valid ,target))
         valid-state)
       #:live-path?
       (lambda (_token target)
         (record! `(live ,target))
         (and live-state
              (or (member target temporary)
                  (member target (map cdr direct)))
              #t))
       #:sync-parent!
       (lambda (_token root)
         (record! `(sync ,root))
         (let ((entry (assoc root direct)))
           (if entry
               (set! registered
                     (acons root
                            (cdr entry)
                            (alist-delete root registered)))
               (set! registered (alist-delete root registered))))
         #t)))
    `((backend . ,backend)
      (events . ,(lambda () events))
      (direct . ,(lambda () direct))
      (registered . ,(lambda () registered))
      (namespaces . ,(lambda () namespaces))
      (opened . ,(lambda () opened))
      (closed . ,(lambda () closed))
      (add-extra!
       . ,(lambda (root target)
            (set! direct (acons root target (alist-delete root direct)))
            (set! registered
                  (acons root target (alist-delete root registered)))))
      (retarget-registration!
       . ,(lambda (root target)
            (set! registered
                  (acons root target (alist-delete root registered)))))
      (drop-registration!
       . ,(lambda (root)
            (set! registered (alist-delete root registered))))
      (drop-root!
       . ,(lambda (root)
            (set! direct (alist-delete root direct))
            (set! registered (alist-delete root registered))))
      (set-valid! . ,(lambda (value) (set! valid-state value)))
      (set-live! . ,(lambda (value) (set! live-state value)))
      (set-open! . ,(lambda (value) (set! open-state value)))
      (add-foreign!
       . ,(lambda (path)
            (set! foreign (cons path foreign)))))))

(define (component synthetic key)
  ((cdr (assq key synthetic))))

(define (capability synthetic key)
  (cdr (assq key synthetic)))

(define %guard-calls '())

(define (accepting-validators)
  (map
   (lambda (key)
     (cons
      key
      (lambda (_manifest phase _state)
        (set! %guard-calls (cons (list key phase) %guard-calls))
        #t)))
   '(protected journal session quiescence)))

(define (check-all-effects-gated labels scope)
  (for-each
   (lambda (label)
     (let ((phase
            (substring label (string-length "after-"))))
       (for-each
        (lambda (key)
          (check
           (member (list key phase) %guard-calls)
           (string-append scope " effect bypassed gate: " phase)))
        '(protected journal session quiescence))))
   labels))

(define (bootstrap! synthetic stop)
  (sk:call-with-root-session
   (cdr (assq 'backend synthetic))
   (lambda (session)
     (sk:bootstrap-orchestrator-program-root!
      session %manifest 'bootstrap (accepting-validators) stop)
     (sk:bootstrap-orchestrator-recovery-roots!
      session %manifest 'bootstrap (accepting-validators) stop)
     (sk:assert-orchestrator-root-set session %manifest))))

(define tuples (sk:orchestrator-root-tuples %manifest))
(define recovery (sk:orchestrator-recovery-root-tuples %manifest))
(define namespace (sk:orchestrator-root-namespace %manifest))

(check (= (length tuples) 5) "root tuple count is not program plus four")
(check (equal? (cdr tuples) recovery)
       "program-first and recovery tuple APIs disagree")
(check (string-prefix? "/var/guix/gcroots/p52b-system-prune-program-"
                       (caar tuples))
       "program root is not first")
(check (every (lambda (tuple)
                (child-of? namespace (car tuple)))
              recovery)
       "managed recovery tuple escapes its namespace")

;; Prove every bootstrap stop boundary is a deterministic restart prefix.
(let* ((baseline (make-synthetic-backend))
       (labels '()))
  (set! %guard-calls '())
  (bootstrap!
   baseline
   (lambda (label)
     (set! labels (append labels (list label)))
     #t))
  (check (= (length labels) 16)
         "split bootstrap stop-boundary count drifted")
  (check (= (length labels) (length (delete-duplicates labels)))
         "bootstrap stop labels are not unique")
  (check-all-effects-gated labels "bootstrap")
  (let ((reentry-labels '()))
    (bootstrap!
     baseline
     (lambda (label)
       (set! reentry-labels (cons label reentry-labels))
       #t))
    (check (= (length reentry-labels) 5)
           (format #f
                   "full-root reentry temp-pin count: ~a ~s"
                   (length reentry-labels)
                   reentry-labels))
    (check (every (lambda (label)
                    (string-prefix? "after-temporary-root:" label))
                  reentry-labels)
           "full-root reentry performed a non-temporary effect"))
  (for-each
   (lambda (target)
     (let ((synthetic (make-synthetic-backend))
           (interrupted? #f))
       (check
        (fails?
         (lambda ()
           (bootstrap!
            synthetic
            (lambda (label)
              (when (and (not interrupted?) (string=? label target))
                (set! interrupted? #t)
                (throw 'synthetic-stop label))
              #t))))
        (string-append "bootstrap stop did not interrupt: " target))
       (check interrupted?
              (string-append "bootstrap boundary was not reached: " target))
       (bootstrap! synthetic (lambda _ #t))))
   labels))

;; A normal transaction effect uses the complete exact-set central gate.
(let ((synthetic (make-synthetic-backend))
      (ran? #f))
  (bootstrap! synthetic (lambda _ #t))
  (sk:call-with-root-session
   (cdr (assq 'backend synthetic))
   (lambda (session)
     (sk:call-with-orchestrator-phase
      session %manifest "transaction-effect" 'forward
      (accepting-validators)
      (lambda () (set! ran? #t) #t))))
  (check ran? "central-gated transaction effect did not run"))

(define (run-cleanup! synthetic root-events
                      terminal-state postflight-state stop)
  (sk:call-with-root-session
   (cdr (assq 'backend synthetic))
   (lambda (session)
     (sk:cleanup-orchestrator-roots!
      session %manifest "COMPLETE" 'cleanup
      (accepting-validators)
      (lambda (event subject)
        (and (member (list event subject) (car root-events)) #t))
      (lambda (event subject)
        (set-car! root-events
                  (append (car root-events)
                          (list (list event subject))))
        #t)
      (lambda (_terminal) (car terminal-state))
      (lambda (_terminal) (set-car! terminal-state #t) #t)
      (lambda (_terminal) (car postflight-state))
      (lambda (_terminal) (set-car! postflight-state #t) #t)
      stop))))

;; Prove every cleanup stop boundary is restartable, including interruption
;; after an individual removal, terminal append, postflight, and program root.
(let* ((baseline (make-synthetic-backend))
       (terminal-state (list #f))
       (postflight-state (list #f))
       (root-events (list '()))
       (labels '()))
  (set! %guard-calls '())
  (bootstrap! baseline (lambda _ #t))
  (set! %guard-calls '())
  (run-cleanup!
   baseline root-events terminal-state postflight-state
   (lambda (label)
     (set! labels (append labels (list label)))
     #t))
  (check (= (length labels) 25)
         "cleanup stop-boundary count drifted")
  (check (= (length labels) (length (delete-duplicates labels)))
         "cleanup stop labels are not unique")
  (check-all-effects-gated labels "cleanup")
  (check (null? (component baseline 'direct))
         "baseline cleanup retained direct roots")
  (check (null? (component baseline 'registered))
         "baseline cleanup retained registrations")
  (check (null? (component baseline 'namespaces))
         "baseline cleanup retained the managed namespace")
  (for-each
   (lambda (target)
     (let ((synthetic (make-synthetic-backend))
           (terminal (list #f))
           (postflight (list #f))
           (root-events (list '()))
           (interrupted? #f))
       (bootstrap! synthetic (lambda _ #t))
       (check
        (fails?
         (lambda ()
           (run-cleanup!
            synthetic root-events terminal postflight
            (lambda (label)
              (when (and (not interrupted?) (string=? label target))
                (set! interrupted? #t)
                (throw 'synthetic-stop label))
              #t))))
        (string-append "cleanup stop did not interrupt: " target))
       (check interrupted?
              (string-append "cleanup boundary was not reached: " target))
       (run-cleanup!
        synthetic root-events terminal postflight (lambda _ #t))
       (check (and (null? (component synthetic 'direct))
                   (null? (component synthetic 'registered))
                   (null? (component synthetic 'namespaces))
                   (car terminal)
                   (car postflight))
              (string-append
               "cleanup reentry did not close prefix: " target))))
   labels))

;; Exact enumeration rejects an extra root and an extra registration before
;; either a normal phase or terminal callback may run.
(for-each
 (lambda (registered-only?)
   (let* ((synthetic (make-synthetic-backend))
          (extra (string-append namespace "/foreign"))
          (target
           "/gnu/store/ffffffffffffffffffffffffffffffff-system")
          (ran? #f))
     (bootstrap! synthetic (lambda _ #t))
     (if registered-only?
         ((capability synthetic 'retarget-registration!) extra target)
         ((capability synthetic 'add-extra!) extra target))
     (check
      (fails?
       (lambda ()
         (sk:call-with-root-session
          (cdr (assq 'backend synthetic))
          (lambda (session)
            (sk:call-with-orchestrator-phase
             session %manifest "transaction-effect" 'forward
             (accepting-validators)
             (lambda () (set! ran? #t)))))))
      "extra managed root set was accepted")
     (check (not ran?) "phase ran after an extra managed root")))
 '(#f #t))

;; Missing/retargeted registration, invalid target, and liveness loss are
;; independent failures at the exact-set gate.
(for-each
 (lambda (mutate! label)
   (let ((synthetic (make-synthetic-backend))
         (ran? #f))
     (bootstrap! synthetic (lambda _ #t))
     (mutate! synthetic)
     (check
      (fails?
       (lambda ()
         (sk:call-with-root-session
          (cdr (assq 'backend synthetic))
          (lambda (session)
            (sk:call-with-orchestrator-phase
             session %manifest "transaction-effect" 'forward
             (accepting-validators)
             (lambda () (set! ran? #t)))))))
      label)
     (check (not ran?) (string-append label " continuation ran"))))
 (list
  (lambda (synthetic)
    ((capability synthetic 'drop-registration!) (caar recovery)))
  (lambda (synthetic)
    ((capability synthetic 'retarget-registration!)
     (caar recovery)
     "/gnu/store/ffffffffffffffffffffffffffffffff-system"))
  (lambda (synthetic)
    ((capability synthetic 'set-valid!) #f))
  (lambda (synthetic)
    ((capability synthetic 'set-live!) #f)))
 '("missing registration was accepted"
   "retargeted registration was accepted"
   "invalid target was accepted"
   "liveness loss was accepted"))

;; All non-root guards, including session and attended quiescence, fail before
;; the continuation.  An open failure never creates a second usable session.
(for-each
 (lambda (key)
   (let ((synthetic (make-synthetic-backend))
         (ran? #f))
     (bootstrap! synthetic (lambda _ #t))
     (let ((validators
            (map (lambda (entry)
                   (if (eq? (car entry) key)
                       (cons key (lambda _ #f))
                       entry))
                 (accepting-validators))))
       (check
        (fails?
         (lambda ()
           (sk:call-with-root-session
            (cdr (assq 'backend synthetic))
            (lambda (session)
              (sk:call-with-orchestrator-phase
               session %manifest "transaction-effect" 'forward validators
               (lambda () (set! ran? #t)))))))
        (string-append "refused guard was accepted: "
                       (symbol->string key)))
       (check (not ran?)
              (string-append "continuation ran after guard refusal: "
                             (symbol->string key))))))
 '(protected journal session quiescence))

(let ((synthetic (make-synthetic-backend)))
  ((capability synthetic 'set-open!) #f)
  (check
   (fails? (lambda () (bootstrap! synthetic (lambda _ #t)))
   )
   "backend session-open failure was accepted")
  (check (= (component synthetic 'opened) 0)
         "failed session was counted as opened")
  (check (= (component synthetic 'closed) 0)
         "failed session invoked the closer"))

;; A removed-root prefix without its durable INTENT is ambiguous and must not
;; be repaired or advanced to terminal state.
(let ((synthetic (make-synthetic-backend))
      (root-events (list '()))
      (terminal (list #f))
      (postflight (list #f)))
  (bootstrap! synthetic (lambda _ #t))
  ((capability synthetic 'drop-root!) (caar recovery))
  (check
   (fails?
    (lambda ()
      (run-cleanup!
       synthetic root-events terminal postflight (lambda _ #t))))
   "absent root without durable intent was reconciled")
  (check (not (car terminal))
         "terminal ran after an unjournaled root removal"))

;; A foreign non-root entry makes an otherwise empty namespace non-empty and
;; blocks namespace removal before terminal/postflight.
(let ((synthetic (make-synthetic-backend))
      (terminal (list #f))
      (postflight (list #f))
      (root-events (list '())))
  (bootstrap! synthetic (lambda _ #t))
  ((capability synthetic 'add-foreign!)
   (string-append namespace "/foreign-non-root"))
  (check
   (fails?
    (lambda ()
      (run-cleanup!
       synthetic root-events terminal postflight (lambda _ #t))))
   "foreign namespace entry was accepted")
  (check (not (car terminal))
         "terminal ran with a foreign namespace entry")
  (check (not (car postflight))
         "postflight ran with a foreign namespace entry"))

(format #t "~a: PASS (~a checks)~%" %program %checks)
