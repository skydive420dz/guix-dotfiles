;;; sk-startup-trace.el --- One-shot startup attribution observer -*- lexical-binding: t; -*-

;; This observer is deliberately dormant during ordinary startup.  Early init
;; loads it only when SK_EMACS_STARTUP_TRACE is exactly "p2.2-v1".  It keeps
;; events in memory: it does not write a report, emit messages, start a process,
;; alter GC policy, or change the eager module order.  Observer overhead remains
;; inside the resulting trace and must never be subtracted from the evidence.

(defconst sk/startup-trace-protocol "sk-emacs-startup-attribution-v1"
  "Machine-readable protocol implemented by the startup observer.")

(defconst sk/startup-trace-activation "p2.2-v1"
  "Exact environment value that activates this one-shot observer.")

(defconst sk/startup-trace-enabled-p
  (equal (getenv "SK_EMACS_STARTUP_TRACE") sk/startup-trace-activation)
  "Non-nil only for an explicitly attributed fresh Emacs process.")

(defconst sk/startup-trace-expected-init-features
  '(use-package
    sk-core sk-ui sk-windows sk-dired sk-terminal sk-dashboard
    sk-completion sk-evil sk-project sk-lsp sk-lisp sk-clojure sk-racket
    sk-fennel sk-lua sk-python sk-shell sk-json sk-c sk-format sk-keys
    sk-org sk-notes)
  "Direct top-level features required by init.el, in exact source order.")

(defvar sk/startup-trace-events nil
  "Chronological in-memory startup events for the current Emacs process.")

(defvar sk/startup-trace-complete-p nil
  "Non-nil after the attributed process reaches window-setup-hook.")

(defvar sk/startup-trace-clock-function #'current-time
  "Zero-argument clock used by the observer.
Tests may bind this to a deterministic clock before calling the observer.")

(defvar sk/startup-trace--bootstrapped-p nil)
(defvar sk/startup-trace--require-depth 0)
(defvar sk/startup-trace--event-sequence 0)
(defvar sk/startup-trace--phase 'early-init)

(defun sk/startup-trace--now ()
  "Return the observer clock's current time value."
  (funcall sk/startup-trace-clock-function))

(defun sk/startup-trace--event-less-p (left right)
  "Return non-nil when event LEFT precedes event RIGHT chronologically."
  (let ((left-start (plist-get left :start))
        (right-start (plist-get right :start)))
    (cond
     ((time-less-p left-start right-start) t)
     ((time-less-p right-start left-start) nil)
     ((time-less-p (plist-get left :end) (plist-get right :end)) t)
     ((time-less-p (plist-get right :end) (plist-get left :end)) nil)
     (t (< (plist-get left :sequence) (plist-get right :sequence))))))

(defun sk/startup-trace--append (event)
  "Insert EVENT into the chronological in-memory trace."
  (setq sk/startup-trace--event-sequence
        (1+ sk/startup-trace--event-sequence))
  (setq event (plist-put event :sequence sk/startup-trace--event-sequence))
  (setq sk/startup-trace-events
        (sort (cons event sk/startup-trace-events)
              #'sk/startup-trace--event-less-p)))

(defun sk/startup-trace--record-mark-at (name time)
  "Record mark NAME at TIME when the observer is active."
  (when (and sk/startup-trace-enabled-p
             (not sk/startup-trace-complete-p))
    (sk/startup-trace--append
     (list :kind "mark"
           :name name
           :start time
           :end time
           :status "ok"
           :already-loaded nil
           :gc-count-delta 0
           :gc-elapsed-delta 0.0))))

(defun sk/startup-trace-mark (name)
  "Record the current time as startup mark NAME.
Return NAME so a guarded marker does not disturb surrounding forms."
  (when (and sk/startup-trace-enabled-p
             (not sk/startup-trace-complete-p))
    ;; Modules loaded during init normally prepend their hooks, which already
    ;; leaves our early APPEND marker last.  Re-arm at init-file exit so the
    ;; tail claim is also explicit if a package used APPEND itself.
    (when (equal name "init-exit")
      (sk/startup-trace--arm-hook-tails))
    (sk/startup-trace--record-mark-at name (sk/startup-trace--now))
    (cond
     ((equal name "init-enter")
      (setq sk/startup-trace--phase 'init))
     ((equal name "exwm-config-enter")
      (setq sk/startup-trace--phase 'exwm-config))
     ((member name '("init-exit" "exwm-config-exit"))
      (setq sk/startup-trace--phase 'bridge))))
  name)

(defun sk/startup-trace--call (kind name function arguments
                                    &optional already-loaded)
  "Call FUNCTION with ARGUMENTS and record an inclusive startup span.
KIND and NAME identify the boundary.  ALREADY-LOADED is meaningful for a
tracked `require' call.  Return values and errors propagate unchanged."
  (if (or (not sk/startup-trace-enabled-p)
          sk/startup-trace-complete-p)
      (apply function arguments)
    (let ((started (sk/startup-trace--now))
          (gc-count-start gcs-done)
          (gc-elapsed-start gc-elapsed)
          (completed nil)
          result)
      (unwind-protect
          (prog1
              (setq result (apply function arguments))
            (setq completed t))
        (let ((ended (sk/startup-trace--now)))
          (sk/startup-trace--append
           (list :kind kind
                 :name name
                 :start started
                 :end ended
                 :status (if completed "ok" "error")
                 :already-loaded already-loaded
                 :gc-count-delta (- gcs-done gc-count-start)
                 :gc-elapsed-delta (- gc-elapsed gc-elapsed-start)))))
      result)))

(defun sk/startup-trace-call (name function &rest arguments)
  "Call FUNCTION with ARGUMENTS inside inclusive attributed span NAME."
  (sk/startup-trace--call "call" name function arguments))

(defun sk/startup-trace--install-dashboard-advice ()
  "Attribute the initial dashboard render when its function is available."
  (when (and (fboundp 'sk/dashboard-buffer)
             (not (advice-member-p #'sk/startup-trace--dashboard-around
                                   'sk/dashboard-buffer)))
    (advice-add 'sk/dashboard-buffer :around
                #'sk/startup-trace--dashboard-around)))

(defun sk/startup-trace--install-exwm-mode-advice ()
  "Attribute EXWM mode activation when its function is available."
  (when (and (fboundp 'exwm-wm-mode)
             (not (advice-member-p #'sk/startup-trace--exwm-mode-around
                                   'exwm-wm-mode)))
    (advice-add 'exwm-wm-mode :around
                #'sk/startup-trace--exwm-mode-around)))

(defun sk/startup-trace--require-around (original &rest arguments)
  "Preserve ORIGINAL `require' while attributing selected outer calls."
  (let* ((feature (car arguments))
         (outermost (zerop sk/startup-trace--require-depth))
         (tracked
          (and outermost
               (or (and (eq sk/startup-trace--phase 'init)
                        (memq feature
                              sk/startup-trace-expected-init-features))
                   (and (eq sk/startup-trace--phase 'exwm-config)
                        (eq feature 'sk-exwm)))))
         (already-loaded (and tracked (featurep feature)))
         (completed nil)
         result)
    (setq sk/startup-trace--require-depth
          (1+ sk/startup-trace--require-depth))
    (unwind-protect
        (prog1
            (setq result
                  (if tracked
                      (sk/startup-trace--call
                       "require" (symbol-name feature) original arguments
                       already-loaded)
                    (apply original arguments)))
          (setq completed t))
      (setq sk/startup-trace--require-depth
            (1- sk/startup-trace--require-depth)))
    (when completed
      (cond
       ((eq feature 'sk-dashboard)
        (sk/startup-trace--install-dashboard-advice))
       ((eq feature 'sk-exwm)
        (sk/startup-trace--install-exwm-mode-advice))))
    result))

(defun sk/startup-trace--dashboard-around (original &rest arguments)
  "Attribute the synchronous dashboard buffer construction."
  (sk/startup-trace--call
   "call" "sk/dashboard-buffer" original arguments))

(defun sk/startup-trace--exwm-mode-around (original &rest arguments)
  "Attribute the synchronous EXWM mode boundary."
  (sk/startup-trace--call "call" "exwm-wm-mode" original arguments))

(defun sk/startup-trace--after-init-hook ()
  "Mark the tail of the configured after-init hook list."
  (sk/startup-trace-mark "after-init-hook-tail"))

(defun sk/startup-trace--emacs-startup-hook ()
  "Mark the tail of the configured Emacs startup hook list."
  (sk/startup-trace-mark "emacs-startup-hook-tail"))

(defun sk/startup-trace--window-setup-hook ()
  "Mark the configured window-setup hook tail and seal the trace."
  (sk/startup-trace-mark "window-setup-hook-tail")
  (sk/startup-trace-finish))

(defun sk/startup-trace--arm-hook-tails ()
  "Place each observer marker at the tail of its current startup hook."
  (dolist (entry
           '((after-init-hook . sk/startup-trace--after-init-hook)
             (emacs-startup-hook . sk/startup-trace--emacs-startup-hook)
             (window-setup-hook . sk/startup-trace--window-setup-hook)))
    (remove-hook (car entry) (cdr entry))
    (add-hook (car entry) (cdr entry) t)))

(defun sk/startup-trace--cleanup ()
  "Remove every observer advice and hook from the live process."
  (advice-remove 'require #'sk/startup-trace--require-around)
  (when (fboundp 'sk/dashboard-buffer)
    (advice-remove 'sk/dashboard-buffer
                   #'sk/startup-trace--dashboard-around))
  (when (fboundp 'exwm-wm-mode)
    (advice-remove 'exwm-wm-mode #'sk/startup-trace--exwm-mode-around))
  (remove-hook 'after-init-hook #'sk/startup-trace--after-init-hook)
  (remove-hook 'emacs-startup-hook #'sk/startup-trace--emacs-startup-hook)
  (remove-hook 'window-setup-hook #'sk/startup-trace--window-setup-hook))

(defun sk/startup-trace-bootstrap (started &optional gc-count-start
                                           gc-elapsed-start)
  "Start a one-shot trace whose observer load began at STARTED.
The observer is installed only once and only under the exact activation flag."
  (when (and sk/startup-trace-enabled-p
             (not sk/startup-trace--bootstrapped-p))
    (setq sk/startup-trace--bootstrapped-p t)
    (sk/startup-trace--record-mark-at "early-init-enter" started)
    (advice-add 'require :around #'sk/startup-trace--require-around)
    (sk/startup-trace--arm-hook-tails)
    (let ((ended (sk/startup-trace--now)))
      (sk/startup-trace--append
       (list :kind "call"
             :name "observer-bootstrap"
             :start started
             :end ended
             :status "ok"
             :already-loaded nil
             :gc-count-delta
             (if (integerp gc-count-start)
                 (- gcs-done gc-count-start)
               0)
             :gc-elapsed-delta
             (if (numberp gc-elapsed-start)
                 (- gc-elapsed gc-elapsed-start)
               0.0))))))

(defun sk/startup-trace-finish ()
  "Seal the one-shot trace and remove all observer hooks and advice."
  (when (and sk/startup-trace-enabled-p
             sk/startup-trace--bootstrapped-p
             (not sk/startup-trace-complete-p))
    (sk/startup-trace-mark "trace-complete")
    (setq sk/startup-trace-complete-p t)
    (sk/startup-trace--cleanup))
  sk/startup-trace-complete-p)

(provide 'sk-startup-trace)

;;; sk-startup-trace.el ends here
