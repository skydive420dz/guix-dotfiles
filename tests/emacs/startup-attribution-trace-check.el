;;; startup-attribution-trace-check.el --- P2.2 trace checks -*- lexical-binding: t; -*-

;; This fixture deliberately exercises the observer without loading the real
;; init modules.  In particular, the synthetic `load' implementation below
;; proves which `require' calls the observer attributes without permitting
;; package startup or desktop side effects in the batch process.

(require 'cl-lib)
(require 'seq)

(defconst sk/startup-trace-test-activation-variable
  "SK_EMACS_STARTUP_TRACE")

(defconst sk/startup-trace-test-activation-value
  "p2.2-v1")

(defconst sk/startup-trace-test-expected-init-features
  '(use-package
    sk-core sk-ui sk-windows sk-dired sk-terminal sk-dashboard
    sk-completion sk-evil sk-project sk-lsp sk-lisp sk-clojure sk-racket
    sk-fennel sk-lua sk-python sk-shell sk-json sk-c sk-format sk-keys
    sk-org sk-notes))

(defun sk/startup-trace-test-source-file ()
  "Return the trace implementation under test."
  (expand-file-name
   "../../emacs/lisp/sk-startup-trace.el"
   (file-name-directory
    (file-truename (or load-file-name buffer-file-name)))))

(defun sk/startup-trace-test-load (activation)
  "Load a fresh observer with ACTIVATION in its exact environment variable."
  (when (featurep 'sk-startup-trace)
    (unload-feature 'sk-startup-trace t))
  (setenv sk/startup-trace-test-activation-variable activation)
  (load (sk/startup-trace-test-source-file) nil 'nomessage))

(defun sk/startup-trace-test-require-advised-p ()
  "Return non-nil when the observer's private `require' advice is installed."
  (and (fboundp 'sk/startup-trace--require-around)
       (advice-member-p #'sk/startup-trace--require-around #'require)))

(defun sk/startup-trace-test-event (kind name &optional events)
  "Return the unique KIND and NAME event from EVENTS or the active trace."
  (let ((matches
         (seq-filter
          (lambda (event)
            (and (equal (plist-get event :kind) kind)
                 (equal (plist-get event :name) name)))
          (or events sk/startup-trace-events))))
    (unless (= (length matches) 1)
      (error "expected one %s/%s event, got %S" kind name matches))
    (car matches)))

(defun sk/startup-trace-test-event-names (kind events)
  "Return the names of KIND events in their recorded order from EVENTS."
  (mapcar (lambda (event) (plist-get event :name))
          (seq-filter (lambda (event)
                        (equal (plist-get event :kind) kind))
                      events)))

(defun sk/startup-trace-test-assert-event-shape (event)
  "Assert EVENT carries the stable P2.2 timing and GC schema."
  (dolist (key '(:kind :name :start :end :status :sequence
                 :gc-count-delta :gc-elapsed-delta))
    (unless (plist-member event key)
      (error "trace event omitted %s: %S" key event)))
  (unless (and (stringp (plist-get event :kind))
               (stringp (plist-get event :name))
               (member (plist-get event :status) '("ok" "error"))
               (natnump (plist-get event :sequence))
               (integerp (plist-get event :gc-count-delta))
               (floatp (plist-get event :gc-elapsed-delta)))
    (error "trace event has invalid field types: %S" event)))

(defun sk/startup-trace-test-buffer-state ()
  "Return a stable identity snapshot of the current buffer set."
  (sort (mapcar #'buffer-name (buffer-list)) #'string<))

(defun sk/startup-trace-test-message-state ()
  "Return the current Messages contents without creating the buffer."
  (when-let ((buffer (get-buffer "*Messages*")))
    (with-current-buffer buffer (buffer-string))))

(let ((original-activation
       (getenv sk/startup-trace-test-activation-variable)))
  (unwind-protect
      (progn
        ;; Activation is an exact opt-in.  Similar-looking, empty, and
        ;; conventional truthy values must leave the observer inert.
        (dolist (activation '(nil "" "1" "true" "P2.2-v1" "p2.2-v1 "))
          (sk/startup-trace-test-load activation)
          (when sk/startup-trace-enabled-p
            (error "inexact activation enabled trace: %S" activation))
          (sk/startup-trace-bootstrap (seconds-to-time 1))
          (when (or sk/startup-trace-events
                    sk/startup-trace-complete-p
                    (sk/startup-trace-test-require-advised-p))
            (error "disabled observer changed state for %S" activation))
          (unless (eq (sk/startup-trace-call "disabled-return" #'identity
                                             'preserved)
                      'preserved)
            (error "disabled trace call changed its return value"))
          (let ((clock-called nil)
                (sk/startup-trace-clock-function
                 (lambda ()
                   (setq clock-called t)
                   (error "disabled mark consulted its clock"))))
            (sk/startup-trace-mark "disabled-mark")
            (when clock-called
              (error "disabled observer was not a strict no-op")))
          (sk/startup-trace-finish)
          (when (or sk/startup-trace-events
                    sk/startup-trace-complete-p
                    (sk/startup-trace-test-require-advised-p))
            (error "disabled observer was not a no-op for %S" activation)))

        (sk/startup-trace-test-load
         sk/startup-trace-test-activation-value)
        (unless sk/startup-trace-enabled-p
          (error "exact activation did not enable observer"))
        (unless (equal sk/startup-trace-protocol
                       "sk-emacs-startup-attribution-v1")
          (error "trace protocol changed: %S" sk/startup-trace-protocol))
        (unless (equal sk/startup-trace-expected-init-features
                       sk/startup-trace-test-expected-init-features)
          (error "tracked init feature order changed: %S"
                 sk/startup-trace-expected-init-features))

        (let* ((before-time (seconds-to-time 10))
               (clock-tick 100)
               (sk/startup-trace-clock-function
                (lambda ()
                  (prog1 (seconds-to-time clock-tick)
                    (setq clock-tick (1+ clock-tick)))))
               (require-definition-before (symbol-function 'require))
               (after-init-hook-before (copy-sequence after-init-hook))
               (emacs-startup-hook-before (copy-sequence emacs-startup-hook))
               (window-setup-hook-before (copy-sequence window-setup-hook))
               (buffers-before (sk/startup-trace-test-buffer-state))
               (processes-before (process-list))
               (messages-before (sk/startup-trace-test-message-state)))
          ;; Any one of these operations would make the observer unsuitable
          ;; for attribution during the measured startup path.
          (cl-letf (((symbol-function 'write-region)
                     (lambda (&rest _)
                       (error "trace attempted to write a file")))
                    ((symbol-function 'make-directory)
                     (lambda (&rest _)
                       (error "trace attempted to create a directory")))
                    ((symbol-function 'rename-file)
                     (lambda (&rest _)
                       (error "trace attempted to rename a file")))
                    ((symbol-function 'copy-file)
                     (lambda (&rest _)
                       (error "trace attempted to copy a file")))
                    ((symbol-function 'delete-file)
                     (lambda (&rest _)
                       (error "trace attempted to delete a file")))
                    ((symbol-function 'message)
                     (lambda (&rest _)
                       (error "trace attempted to display a message")))
                    ((symbol-function 'start-process)
                     (lambda (&rest _)
                       (error "trace attempted to start a process")))
                    ((symbol-function 'make-process)
                     (lambda (&rest _)
                       (error "trace attempted to make a process")))
                    ((symbol-function 'call-process)
                     (lambda (&rest _)
                       (error "trace attempted to call a process"))))
            (sk/startup-trace-bootstrap before-time)
            (unless (sk/startup-trace-test-require-advised-p)
              (error "bootstrap did not install require attribution"))

            (let ((entry
                   (sk/startup-trace-test-event
                    "mark" "early-init-enter")))
              (unless (and (equal (plist-get entry :start) before-time)
                           (equal (plist-get entry :end) before-time))
                (error "bootstrap lost supplied startup boundary: %S" entry)))

            ;; A mark uses the injected clock once and has one exact instant.
            (let* ((mark-time (seconds-to-time 500))
                   (clock-values (list mark-time))
                   (sk/startup-trace-clock-function
                    (lambda ()
                      (or (pop clock-values)
                          (error "mark read the clock more than once")))))
              (sk/startup-trace-mark "fixture-mark")
              (let ((event
                     (sk/startup-trace-test-event "mark" "fixture-mark")))
                (unless (and (equal (plist-get event :start) mark-time)
                             (equal (plist-get event :end) mark-time))
                  (error "mark ignored injected clock: %S" event)))
              (setq clock-tick 501))

            ;; Generic calls preserve arguments and returns while reporting
            ;; the observer cost boundary and the GC counters it spans.
            (let* ((start-time (seconds-to-time 600))
                   (end-time (seconds-to-time 603))
                   (clock-values (list start-time end-time))
                   (sk/startup-trace-clock-function
                    (lambda ()
                      (or (pop clock-values)
                          (error "call read the clock more than twice"))))
                   (gcs-done 7)
                   (gc-elapsed 1.25)
                   (result
                    (sk/startup-trace-call
                     "fixture-call"
                     (lambda (left right)
                       (setq gcs-done 9
                             gc-elapsed 1.5)
                       (list right left))
                     'left 'right))
                   (event
                    (sk/startup-trace-test-event "call" "fixture-call")))
              (unless (equal result '(right left))
                (error "trace call changed return/argument semantics: %S"
                       result))
              (unless (and (equal (plist-get event :start) start-time)
                           (equal (plist-get event :end) end-time)
                           (equal (plist-get event :status) "ok")
                           (= (plist-get event :gc-count-delta) 2)
                           (= (plist-get event :gc-elapsed-delta) 0.25))
                (error "trace call recorded the wrong boundary: %S" event))
              (setq clock-tick 604))

            ;; Errors must be re-signaled as the original condition after an
            ;; error event has been appended.
            (let ((caught nil))
              (condition-case condition
                  (sk/startup-trace-call
                   "fixture-error"
                   (lambda () (signal 'file-error '("fixture"))))
                (file-error (setq caught condition)))
              (unless (equal caught '(file-error "fixture"))
                (error "trace call changed/suppressed error: %S" caught))
              (unless (equal (plist-get
                              (sk/startup-trace-test-event
                               "call" "fixture-error")
                              :status)
                             "error")
                (error "trace did not record call error status")))

            ;; Model an outer top-level expected require whose implementation
            ;; itself requires another expected feature.  Only the outer call
            ;; belongs to the init critical path.  The later direct require of
            ;; the now-loaded inner feature is separately attributed and
            ;; marked already-loaded.
            (sk/startup-trace-mark "init-enter")
            (let ((features
                   (delq 'sk-exwm
                         (delq 'sk-ui
                               (delq 'sk-core
                                     (delq 'use-package
                                           (copy-sequence features)))))))
              (cl-labels
                  ((synthetic-require
                    (feature &rest _arguments)
                    (pcase feature
                      ('use-package
                       ;; Exercise the advice recursively, as a real feature
                       ;; load would.  The depth guard must exclude sk-core.
                       (sk/startup-trace--require-around
                        #'synthetic-require 'sk-core)
                       (provide feature))
                      ('sk-ui
                       (signal 'file-error
                               '("synthetic require failure")))
                      (_ (provide feature)))))
                (sk/startup-trace--require-around
                 #'synthetic-require 'use-package)
                (sk/startup-trace--require-around
                 #'synthetic-require 'sk-core)
                (sk/startup-trace--require-around
                 #'synthetic-require 'cl-lib)
                (let ((caught nil))
                  (condition-case condition
                      (sk/startup-trace--require-around
                       #'synthetic-require 'sk-ui)
                    (file-error (setq caught condition)))
                  (unless (equal caught
                                 '(file-error "synthetic require failure"))
                    (error "require advice changed/suppressed error: %S"
                           caught)))
                (sk/startup-trace-mark "init-exit")
                (sk/startup-trace-mark "exwm-config-enter")
                (sk/startup-trace--require-around
                 #'synthetic-require 'sk-exwm)
                (sk/startup-trace-mark "exwm-config-exit"))
              (let* ((events (copy-sequence sk/startup-trace-events))
                     (requires
                      (seq-filter
                       (lambda (event)
                         (equal (plist-get event :kind) "require"))
                       events)))
                (unless (equal
                         (mapcar (lambda (event) (plist-get event :name))
                                 requires)
                         '("use-package" "sk-core" "sk-ui" "sk-exwm"))
                  (error "require attribution was nested/out of order: %S"
                         requires))
                (unless (and
                         (null (plist-get (nth 0 requires) :already-loaded))
                         (eq (plist-get (nth 1 requires) :already-loaded) t)
                         (null (plist-get (nth 2 requires) :already-loaded))
                         (equal (plist-get (nth 2 requires) :status) "error")
                         (null (plist-get (nth 3 requires) :already-loaded)))
                  (error "require identity/status is wrong: %S" requires))))

            ;; Nested spans complete inside-out.  The stored trace must still
            ;; be canonical start/end/sequence order rather than append order.
            (let* ((clock-values
                    (mapcar #'seconds-to-time '(700 701 702 703)))
                   (sk/startup-trace-clock-function
                    (lambda ()
                      (or (pop clock-values)
                          (error "nested calls over-read their clock")))))
              (unless (eq
                       (sk/startup-trace-call
                        "outer-span"
                        (lambda ()
                          (sk/startup-trace-call
                           "inner-span" (lambda () 'nested-result))))
                       'nested-result)
                (error "nested trace calls changed their return value"))
              (let ((outer
                     (sk/startup-trace-test-event "call" "outer-span"))
                    (inner
                     (sk/startup-trace-test-event "call" "inner-span")))
                (unless (> (plist-get outer :sequence)
                           (plist-get inner :sequence))
                  (error "nested fixture did not complete inside-out")))
              (setq clock-tick 704))

            (let ((count-before (length sk/startup-trace-events)))
              (sk/startup-trace-finish)
              (unless (and sk/startup-trace-complete-p
                           (= (length sk/startup-trace-events)
                              (1+ count-before)))
                (error "finish did not append exactly one completion mark"))
              (unless (equal
                       (sk/startup-trace-test-event-names
                        "mark" sk/startup-trace-events)
                       '("early-init-enter" "fixture-mark" "init-enter"
                         "init-exit" "exwm-config-enter" "exwm-config-exit"
                         "trace-complete"))
                (error "trace marks are not chronological: %S"
                       sk/startup-trace-events))
              (when (sk/startup-trace-test-require-advised-p)
                (error "finish left require advice installed"))
              (sk/startup-trace-finish)
              (unless (= (length sk/startup-trace-events)
                         (1+ count-before))
                (error "finish was not idempotent"))))

          (unless (eq (symbol-function 'require) require-definition-before)
            (error "observer did not restore the original require function"))
          (unless (equal after-init-hook after-init-hook-before)
            (error "observer leaked an after-init hook"))
          (unless (equal emacs-startup-hook emacs-startup-hook-before)
            (error "observer leaked an emacs-startup hook"))
          (unless (equal window-setup-hook window-setup-hook-before)
            (error "observer leaked a window-setup hook"))
          (unless (equal (sk/startup-trace-test-buffer-state) buffers-before)
            (error "observer changed the buffer set"))
          (unless (equal (process-list) processes-before)
            (error "observer changed the process set"))
          (unless (equal (sk/startup-trace-test-message-state)
                         messages-before)
            (error "observer changed *Messages*"))
          (dolist (event sk/startup-trace-events)
            (sk/startup-trace-test-assert-event-shape event))
          (unless (equal
                   (mapcar (lambda (event)
                             (cons (plist-get event :kind)
                                   (plist-get event :name)))
                           sk/startup-trace-events)
                   '(("mark" . "early-init-enter")
                     ("call" . "observer-bootstrap")
                     ("mark" . "fixture-mark")
                     ("call" . "fixture-call")
                     ("call" . "fixture-error")
                     ("mark" . "init-enter")
                     ("require" . "use-package")
                     ("require" . "sk-core")
                     ("require" . "sk-ui")
                     ("mark" . "init-exit")
                     ("mark" . "exwm-config-enter")
                     ("require" . "sk-exwm")
                     ("mark" . "exwm-config-exit")
                     ("call" . "outer-span")
                     ("call" . "inner-span")
                     ("mark" . "trace-complete")))
            (error "complete event sequence changed: %S"
                   sk/startup-trace-events)))

        (princ "emacs-startup-attribution-trace-check: PASS\n"))
    (ignore-errors
      (when (and (boundp 'sk/startup-trace-enabled-p)
                 sk/startup-trace-enabled-p
                 (fboundp 'sk/startup-trace-finish))
        (sk/startup-trace-finish)))
    (setenv sk/startup-trace-test-activation-variable
            original-activation)))

;;; startup-attribution-trace-check.el ends here
