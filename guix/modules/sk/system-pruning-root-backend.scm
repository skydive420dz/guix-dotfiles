;;; Pure dependency-injection contract for System-pruning recovery roots.

(define-module (sk system-pruning-root-backend)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (sk:call-with-root-session
            sk:make-root-backend
            sk:root-backend?
            sk:root-backend-name
            sk:root-session-add-temp-root!
            sk:root-session-create-namespace!
            sk:root-session-create-direct-root!
            sk:root-session-direct-root-target
            sk:root-session-direct-roots
            sk:root-session-live-path?
            sk:root-session-namespace-empty?
            sk:root-session-namespace-state
            sk:root-session-registered-roots
            sk:root-session-registered-root-target
            sk:root-session-remove-namespace!
            sk:root-session-remove-direct-root!
            sk:root-session-sync-parent!
            sk:root-session-valid-path?))

(define %error-key 'sk-system-pruning-root-backend)

(define (%fail format-string . arguments)
  (throw %error-key (apply format #f format-string arguments)))

(define (ensure condition format-string . arguments)
  (unless condition
    (apply %fail format-string arguments)))

(define (safe-label? value)
  (and (string? value)
       (not (string-null? value))
       (every
        (lambda (character)
          (or (char-alphabetic? character)
              (char-numeric? character)
              (memv character '(#\- #\_ #\.))))
        (string->list value))))

(define (normalized-absolute-path? value)
  (and (string? value)
       (absolute-file-name? value)
       (not (string=? value "/"))
       (not (string-suffix? "/" value))
       (not (string-contains value "//"))
       (not (string-contains value "/./"))
       (not (string-contains value "/../"))
       (not (string-suffix? "/." value))
       (not (string-suffix? "/.." value))))

(define-record-type <root-backend>
  (%make-root-backend name
                      open
                      close
                      add-temp-root!
                      direct-root-target
                      registered-root-target
                      direct-roots
                      registered-roots
                      namespace-state
                      create-namespace!
                      remove-namespace!
                      namespace-empty?
                      create-direct-root!
                      remove-direct-root!
                      valid-path?
                      live-path?
                      sync-parent!)
  sk:root-backend?
  (name sk:root-backend-name)
  (open root-backend-open)
  (close root-backend-close)
  (add-temp-root! root-backend-add-temp-root!)
  (direct-root-target root-backend-direct-root-target)
  (registered-root-target root-backend-registered-root-target)
  (direct-roots root-backend-direct-roots)
  (registered-roots root-backend-registered-roots)
  (namespace-state root-backend-namespace-state)
  (create-namespace! root-backend-create-namespace!)
  (remove-namespace! root-backend-remove-namespace!)
  (namespace-empty? root-backend-namespace-empty?)
  (create-direct-root! root-backend-create-direct-root!)
  (remove-direct-root! root-backend-remove-direct-root!)
  (valid-path? root-backend-valid-path?)
  (live-path? root-backend-live-path?)
  (sync-parent! root-backend-sync-parent!))

(define-record-type <root-session>
  (%make-root-session backend token open?)
  root-session?
  (backend root-session-backend)
  (token root-session-token)
  (open? root-session-open? set-root-session-open?!))

(define* (sk:make-root-backend
          #:key
          name
          open
          close
          add-temp-root!
          direct-root-target
          registered-root-target
          direct-roots
          registered-roots
          namespace-state
          create-namespace!
          remove-namespace!
          namespace-empty?
          create-direct-root!
          remove-direct-root!
          valid-path?
          live-path?
          sync-parent!)
  "Return a validated, inert recovery-root backend contract.

The procedures are injected capabilities.  This module opens no store
connection and performs no filesystem operation itself."
  (ensure (safe-label? name) "root backend name is unsafe: ~s" name)
  (for-each
   (lambda (binding)
     (ensure (procedure? (cdr binding))
             "root backend procedure is missing: ~a"
             (car binding)))
   `((open . ,open)
     (close . ,close)
     (add-temp-root! . ,add-temp-root!)
     (direct-root-target . ,direct-root-target)
     (registered-root-target . ,registered-root-target)
     (direct-roots . ,direct-roots)
     (registered-roots . ,registered-roots)
     (namespace-state . ,namespace-state)
     (create-namespace! . ,create-namespace!)
     (remove-namespace! . ,remove-namespace!)
     (namespace-empty? . ,namespace-empty?)
     (create-direct-root! . ,create-direct-root!)
     (remove-direct-root! . ,remove-direct-root!)
     (valid-path? . ,valid-path?)
     (live-path? . ,live-path?)
     (sync-parent! . ,sync-parent!)))
  (%make-root-backend name
                      open
                      close
                      add-temp-root!
                      direct-root-target
                      registered-root-target
                      direct-roots
                      registered-roots
                      namespace-state
                      create-namespace!
                      remove-namespace!
                      namespace-empty?
                      create-direct-root!
                      remove-direct-root!
                      valid-path?
                      live-path?
                      sync-parent!))

(define (assert-open-session session)
  (ensure (root-session? session) "value is not a root session")
  (ensure (root-session-open? session)
          "root session is already closed: ~a"
          (sk:root-backend-name (root-session-backend session)))
  session)

(define (assert-path value label)
  (ensure (normalized-absolute-path? value)
          "~a is not a normalized absolute path: ~s"
          label value)
  value)

(define (assert-success value operation)
  (ensure (eq? value #t)
          "root backend ~a did not return exact success"
          operation)
  #t)

(define (call-session session accessor . arguments)
  (let* ((session (assert-open-session session))
         (backend (root-session-backend session))
         (procedure (accessor backend)))
    (apply procedure (root-session-token session) arguments)))

(define (sk:call-with-root-session backend procedure)
  "Call PROCEDURE once with a session opened by BACKEND.

The injected close capability runs exactly once through `dynamic-wind', even
when PROCEDURE exits nonlocally.  Session capabilities reject use after close."
  (ensure (sk:root-backend? backend) "value is not a root backend")
  (ensure (procedure? procedure) "root-session consumer is not a procedure")
  (let ((token ((root-backend-open backend))))
    (ensure token
            "root backend returned a false session token: ~a"
            (sk:root-backend-name backend))
    (let ((session (%make-root-session backend token #t)))
      (dynamic-wind
        (const #t)
        (lambda () (procedure session))
        (lambda ()
          (when (root-session-open? session)
            ;; Mark the wrapper closed before invoking the injected closer so
            ;; even a failing closer cannot leave a reusable capability.
            (set-root-session-open?! session #f)
            (assert-success
             ((root-backend-close backend) token)
             "close")))))))

(define (sk:root-session-add-temp-root! session target)
  "Temporarily protect TARGET for the lifetime of SESSION."
  (assert-path target "temporary-root target")
  (assert-success
   (call-session session root-backend-add-temp-root! target)
   "add-temp-root"))

(define (observed-root-target session root accessor kind)
  (assert-path root "direct-root path")
  (let ((target (call-session session accessor root)))
    (ensure (or (not target) (normalized-absolute-path? target))
            "root backend returned an unsafe ~a target: ~s"
            kind
            target)
    target))

(define (sk:root-session-direct-root-target session root)
  "Return ROOT's exact direct symlink target, or #f when absent."
  (observed-root-target
   session root root-backend-direct-root-target "direct-root"))

(define (sk:root-session-registered-root-target session root)
  "Return ROOT's daemon-visible target, or #f when unregistered."
  (observed-root-target
   session root root-backend-registered-root-target "registered-root"))

(define (assert-root-tuples value namespace kind)
  (ensure (list? value)
          "root backend returned a non-list ~a enumeration" kind)
  (for-each
   (lambda (tuple)
     (ensure (and (list? tuple)
                  (= (length tuple) 2))
             "root backend returned a malformed ~a tuple: ~s"
             kind tuple)
     (let ((root (car tuple))
           (target (cadr tuple))
           (prefix (string-append namespace "/")))
       (assert-path root (string-append kind " root"))
       (assert-path target (string-append kind " target"))
       (ensure (and (string-prefix? prefix root)
                    (not (string-contains
                          (substring root (string-length prefix))
                          "/")))
               "~a root escapes its managed namespace: ~a"
               kind root)))
   value)
  (ensure (= (length value)
             (length (delete-duplicates (map car value))))
          "root backend returned duplicate ~a paths" kind)
  value)

(define (observed-roots session namespace accessor kind)
  (assert-path namespace "managed root namespace")
  (assert-root-tuples
   (call-session session accessor namespace)
   namespace
   kind))

(define (sk:root-session-direct-roots session namespace)
  "Return every direct root tuple immediately within managed NAMESPACE."
  (observed-roots session namespace root-backend-direct-roots "direct"))

(define (sk:root-session-registered-roots session namespace)
  "Return every daemon-registered tuple immediately within NAMESPACE."
  (observed-roots
   session namespace root-backend-registered-roots "registered"))

(define (sk:root-session-namespace-state session namespace)
  "Return `absent' or `directory' for managed NAMESPACE."
  (assert-path namespace "managed root namespace")
  (let ((state
         (call-session session root-backend-namespace-state namespace)))
    (ensure (memq state '(absent directory))
            "root backend returned an unsafe namespace state: ~s"
            state)
    state))

(define (sk:root-session-create-namespace! session namespace)
  "Create managed NAMESPACE without creating a root."
  (assert-path namespace "managed root namespace")
  (assert-success
   (call-session session root-backend-create-namespace! namespace)
   "create-namespace"))

(define (sk:root-session-remove-namespace! session namespace)
  "Remove an already-empty managed NAMESPACE."
  (assert-path namespace "managed root namespace")
  (assert-success
   (call-session session root-backend-remove-namespace! namespace)
   "remove-namespace"))

(define (sk:root-session-namespace-empty? session namespace)
  "Return whether managed NAMESPACE contains no entry of any kind."
  (assert-path namespace "managed root namespace")
  (let ((result
         (call-session session root-backend-namespace-empty? namespace)))
    (ensure (boolean? result)
            "root backend returned a non-boolean namespace emptiness result")
    result))

(define (sk:root-session-create-direct-root! session root target)
  "Create the exact direct ROOT -> TARGET tuple through SESSION."
  (assert-path root "direct-root path")
  (assert-path target "direct-root target")
  (assert-success
   (call-session session
                 root-backend-create-direct-root!
                 root
                 target)
   "create-direct-root"))

(define (sk:root-session-remove-direct-root! session root target)
  "Remove ROOT only when it still points to exact TARGET."
  (assert-path root "direct-root path")
  (assert-path target "direct-root target")
  (assert-success
   (call-session session
                 root-backend-remove-direct-root!
                 root
                 target)
   "remove-direct-root"))

(define (sk:root-session-valid-path? session target)
  "Return the backend's exact boolean validity result for TARGET."
  (assert-path target "validity target")
  (let ((result
         (call-session session root-backend-valid-path? target)))
    (ensure (boolean? result)
            "root backend returned a non-boolean validity result")
    result))

(define (sk:root-session-live-path? session target)
  "Return the backend's exact boolean liveness result for TARGET.

Only point membership is exposed; the backend's complete live set never
crosses this contract."
  (assert-path target "liveness target")
  (let ((result
         (call-session session root-backend-live-path? target)))
    (ensure (boolean? result)
            "root backend returned a non-boolean liveness result")
    result))

(define (sk:root-session-sync-parent! session root)
  "Synchronize the parent namespace containing ROOT through SESSION."
  (assert-path root "direct-root path")
  (assert-success
   (call-session session root-backend-sync-parent! root)
   "sync-parent"))
