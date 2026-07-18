;;; early-init-watchdog-failure-check.el --- Full-load fail-open fixture -*- lexical-binding: t; -*-

;;; Commentary:

;; Load the tracked early init from a fresh Emacs while forcing watchdog timer
;; registration to fail.  This catches ordering regressions that a function-
;; level ERT cannot see: every alpha owner must already exist when the
;; immediate fail-open cleanup runs, and none may be reinstalled afterward.

;;; Code:

(require 'cl-lib)

(let* ((source-root
        (file-name-as-directory
         (or (getenv "SK_EMACS_CHECK_SOURCE_ROOT")
             (error "SK_EMACS_CHECK_SOURCE_ROOT is required"))))
       (early-init
        (expand-file-name "emacs/early-init.el" source-root))
       (process-environment (copy-sequence process-environment))
       (initial-window-system 'x)
       (initial-frame-alist nil)
       (default-frame-alist nil)
       (window-setup-hook nil)
       (frame-alpha-lower-limit 20)
       warning)
  (setenv "SK_EMACS_STARTUP_OPACITY_PERCENT" "85")
  (cl-letf (((symbol-function 'run-at-time)
             (lambda (&rest _arguments)
               (error "deliberate watchdog registration failure")))
            ((symbol-function 'display-warning)
             (lambda (_type message &optional _level _buffer-name)
               (setq warning message))))
    (load early-init nil nil))
  (unless
      (and (not sk/startup-frame-gate-active-p)
           sk/startup-frame-gate-release-complete-p
           (= frame-alpha-lower-limit 20)
           (not (assq 'alpha initial-frame-alist))
           (not (assq 'alpha default-frame-alist))
           (not (memq #'sk/startup-frame-schedule-release
                      window-setup-hook))
           (null sk/startup-frame-gate-watchdog-timer)
           (null sk/startup-frame-gate-release-timer)
           (null sk/startup-frame-geometry-deadline)
           (null (getenv
                  sk/startup-frame-opacity-environment-variable))
           (stringp warning)
           (string-match-p "Could not schedule startup-frame watchdog"
                           warning))
    (error
     (concat
      "early-init watchdog failure did not clean every alpha owner: "
      "gate=%S complete=%S floor=%S initial=%S default=%S hook=%S "
      "watchdog=%S release=%S deadline=%S token=%S warning=%S")
     sk/startup-frame-gate-active-p
     sk/startup-frame-gate-release-complete-p
     frame-alpha-lower-limit
     (assq 'alpha initial-frame-alist)
     (assq 'alpha default-frame-alist)
     (memq #'sk/startup-frame-schedule-release window-setup-hook)
     sk/startup-frame-gate-watchdog-timer
     sk/startup-frame-gate-release-timer
     sk/startup-frame-geometry-deadline
     (getenv sk/startup-frame-opacity-environment-variable)
     warning))
  (message "early-init watchdog registration failure: PASS"))

;;; early-init-watchdog-failure-check.el ends here
