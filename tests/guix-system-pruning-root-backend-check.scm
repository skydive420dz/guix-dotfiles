;;; Deterministic tests for the pure System-pruning root-backend contract.

(use-modules (sk system-pruning-root-backend)
             (srfi srfi-1))

(define %program "guix-system-pruning-root-backend-check")

(define (fail format-string . arguments)
  (format (current-error-port)
          "~a: FAIL: ~a~%"
          %program
          (apply format #f format-string arguments))
  (exit 1))

(define (check condition label)
  (unless condition (fail "~a" label)))

(define (check-equal actual expected label)
  (check (equal? actual expected)
         (format #f "~a: expected ~s, got ~s" label expected actual)))

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

(define events '())
(define namespaces '())
(define direct '())
(define registered '())
(define live '())
(define captured-session #f)
(define token-counter 0)

(define (record! event)
  (set! events (append events (list event)))
  #t)

(define backend
  (sk:make-root-backend
   #:name "synthetic"
   #:open
   (lambda ()
     (set! token-counter (+ token-counter 1))
     (record! `(open ,token-counter))
     token-counter)
   #:close (lambda (token) (record! `(close ,token)))
   #:add-temp-root!
   (lambda (token target)
     (record! `(temporary ,token ,target))
     (set! live (cons target live))
     #t)
   #:direct-root-target
   (lambda (_token root) (and=> (assoc root direct) cdr))
   #:registered-root-target
   (lambda (_token root) (and=> (assoc root registered) cdr))
   #:direct-roots
   (lambda (_token namespace)
     (filter-map
      (lambda (entry)
        (and (child-of? namespace (car entry))
             (list (car entry) (cdr entry))))
      direct))
   #:registered-roots
   (lambda (_token namespace)
     (filter-map
      (lambda (entry)
        (and (child-of? namespace (car entry))
             (list (car entry) (cdr entry))))
      registered))
   #:namespace-state
   (lambda (_token namespace)
     (if (member namespace namespaces) 'directory 'absent))
   #:create-namespace!
   (lambda (_token namespace)
     (set! namespaces (cons namespace namespaces))
     #t)
   #:remove-namespace!
   (lambda (_token namespace)
     (and (not (any (lambda (entry)
                      (child-of? namespace (car entry)))
                    direct))
          (begin
            (set! namespaces (delete namespace namespaces))
            #t)))
   #:namespace-empty?
   (lambda (_token namespace)
     (not (any (lambda (entry)
                 (child-of? namespace (car entry)))
               direct)))
   #:create-direct-root!
   (lambda (_token root target)
     (and (not (assoc root direct))
          (begin
            (set! direct (acons root target direct))
            #t)))
   #:remove-direct-root!
   (lambda (_token root target)
     (let ((entry (assoc root direct)))
       (and entry
            (string=? (cdr entry) target)
            (begin
              (set! direct (alist-delete root direct))
              (set! registered (alist-delete root registered))
              #t))))
   #:valid-path? (lambda (_token target) (string-prefix? "/gnu/store/" target))
   #:live-path? (lambda (_token target) (and (member target live) #t))
   #:sync-parent!
   (lambda (_token root)
     (let ((entry (assoc root direct)))
       (if entry
           (set! registered
                 (acons root (cdr entry) (alist-delete root registered)))
           (set! registered (alist-delete root registered))))
     #t)))

(define namespace "/synthetic/roots")
(define target "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system")
(define root (string-append namespace "/candidate"))

(check (sk:root-backend? backend) "constructor returned no backend")
(check-equal (sk:root-backend-name backend) "synthetic" "backend name")

(check-equal
 (sk:call-with-root-session
  backend
  (lambda (session)
    (set! captured-session session)
    (check-equal
     (sk:root-session-namespace-state session namespace)
     'absent
     "initial namespace state")
    (sk:root-session-create-namespace! session namespace)
    (check (sk:root-session-namespace-empty? session namespace)
           "new namespace is not empty")
    (sk:root-session-add-temp-root! session target)
    (sk:root-session-create-direct-root! session root target)
    (check-equal
     (sk:root-session-direct-roots session namespace)
     `((,root ,target))
     "direct enumeration")
    (check-equal
     (sk:root-session-registered-roots session namespace)
     '()
     "registration was conflated with a direct root")
    (check (not (sk:root-session-namespace-empty? session namespace))
           "occupied namespace was reported empty")
    (sk:root-session-sync-parent! session root)
    (check-equal
     (sk:root-session-registered-roots session namespace)
     `((,root ,target))
     "registered enumeration")
    (check (sk:root-session-valid-path? session target)
           "valid target was rejected")
    (check (sk:root-session-live-path? session target)
           "temporary target was not live")
    (sk:root-session-remove-direct-root! session root target)
    (check (sk:root-session-namespace-empty? session namespace)
           "removed root remained in the namespace")
    (sk:root-session-remove-namespace! session namespace)
    'complete))
 'complete
 "session result")

(check-equal (car events) '(open 1) "first session event")
(check-equal (last events) '(close 1) "last session event")
(check (fails?
        (lambda ()
          (sk:root-session-namespace-state captured-session namespace)))
       "closed session remained usable")

;; Nonlocal failure closes exactly the one opened token.
(let ((before (length events)))
  (check
   (fails?
    (lambda ()
      (sk:call-with-root-session
       backend
       (lambda (_session) (throw 'deliberate-failure)))))
   "nonlocal session failure was accepted")
  (check-equal
   (drop events before)
   '((open 2) (close 2))
   "nonlocal close order"))

(define (base-malformed-backend overrides)
  (define (value key fallback)
    (let ((entry (assq key overrides)))
      (if entry (cdr entry) fallback)))
  (sk:make-root-backend
   #:name "malformed"
   #:open (value 'open (lambda () 'token))
   #:close (value 'close (lambda _ #t))
   #:add-temp-root! (value 'add-temp-root! (lambda _ #t))
   #:direct-root-target (value 'direct-root-target (lambda _ #f))
   #:registered-root-target (value 'registered-root-target (lambda _ #f))
   #:direct-roots (value 'direct-roots (lambda _ '()))
   #:registered-roots (value 'registered-roots (lambda _ '()))
   #:namespace-state (value 'namespace-state (lambda _ 'absent))
   #:create-namespace! (value 'create-namespace! (lambda _ #t))
   #:remove-namespace! (value 'remove-namespace! (lambda _ #t))
   #:namespace-empty? (value 'namespace-empty? (lambda _ #t))
   #:create-direct-root! (value 'create-direct-root! (lambda _ #t))
   #:remove-direct-root! (value 'remove-direct-root! (lambda _ #t))
   #:valid-path? (value 'valid-path? (lambda _ #t))
   #:live-path? (value 'live-path? (lambda _ #t))
   #:sync-parent! (value 'sync-parent! (lambda _ #t))))

;; Enumeration is closed: malformed tuples, nested paths, duplicates, unsafe
;; targets, and non-list values all fail before orchestration can use them.
(for-each
 (lambda (result)
   (let ((candidate
          (base-malformed-backend
           `((direct-roots . ,(lambda _ result))))))
     (check
      (fails?
       (lambda ()
         (sk:call-with-root-session
          candidate
          (lambda (session)
            (sk:root-session-direct-roots session namespace)))))
      "malformed direct enumeration was accepted")))
 (list
  'not-a-list
  '(("only-one-field"))
  `(("/synthetic/roots/nested/root" ,target))
  `(("/synthetic/roots/a" "relative"))
  `(("/synthetic/roots/a" ,target)
    ("/synthetic/roots/a" ,target))))

(for-each
 (lambda (override probe label)
   (let ((candidate (base-malformed-backend (list override))))
     (check
      (fails?
       (lambda ()
         (sk:call-with-root-session candidate probe)))
      label)))
 `((namespace-state . ,(lambda _ 'symlink))
   (namespace-empty? . ,(lambda _ 'yes))
   (create-namespace! . ,(lambda _ 'yes)))
 (list
  (lambda (session)
    (sk:root-session-namespace-state session namespace))
  (lambda (session)
    (sk:root-session-namespace-empty? session namespace))
  (lambda (session)
    (sk:root-session-create-namespace! session namespace)))
 '("unsafe namespace state was accepted"
   "non-boolean namespace emptiness was accepted"
   "non-exact namespace mutation success was accepted"))

;; Constructor capability closure and path normalization are mandatory.
(check
 (fails?
  (lambda ()
    (base-malformed-backend '((direct-roots . #f)))))
 "missing enumeration capability was accepted")
(check
 (fails?
  (lambda ()
    (sk:call-with-root-session
     backend
     (lambda (session)
       (sk:root-session-namespace-state session "/")))))
 "live root namespace was accepted")
(check
 (fails?
  (lambda ()
    (sk:call-with-root-session
     backend
     (lambda (session)
       (sk:root-session-direct-roots session "/synthetic/roots/")))))
 "trailing-slash namespace was accepted")

(format #t "~a: PASS~%" %program)
