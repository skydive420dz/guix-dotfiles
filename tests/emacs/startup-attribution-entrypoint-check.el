;;; startup-attribution-entrypoint-check.el --- Live entrypoint fixture -*- lexical-binding: t; -*-

(let* ((source-root
        (file-name-as-directory
         (file-truename
          (or (getenv "SK_EMACS_STARTUP_ATTRIBUTION_SOURCE_ROOT")
              (error "SK_EMACS_STARTUP_ATTRIBUTION_SOURCE_ROOT is required")))))
       (entrypoint (expand-file-name "early-init.el" user-emacs-directory))
       (expected-entrypoint (expand-file-name "emacs/early-init.el" source-root)))
  (unless (file-symlink-p entrypoint)
    (error "startup attribution entrypoint is not a symlink: %s" entrypoint))
  (unless (equal (file-truename entrypoint)
                 (file-truename expected-entrypoint))
    (error "startup attribution entrypoint targets the wrong source: %s"
           entrypoint))
  (unwind-protect
      (progn
        ;; Load the same ~/.emacs.d symlink used by the live EXWM process.  A
        ;; source load would hide regressions that resolve lisp/ relative to
        ;; user-emacs-directory instead of the repository source directory.
        (load entrypoint nil 'nomessage)
        (unless (and (featurep 'sk-startup-trace)
                     (bound-and-true-p sk/startup-trace-enabled-p))
          (error "symlinked early-init did not enable startup attribution"))
        (unless (and (boundp 'sk/native-comp-profile-key)
                     (stringp sk/native-comp-profile-key))
          (error "symlinked early-init did not finish native-cache setup"))
        (princ "startup-attribution-entrypoint-check: PASS\n"))
    (when (fboundp 'sk/startup-trace-finish)
      (sk/startup-trace-finish))))

;;; startup-attribution-entrypoint-check.el ends here
