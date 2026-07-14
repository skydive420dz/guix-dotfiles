;;; batch-bootstrap.el --- Warning capture for isolated checks -*- lexical-binding: t; -*-

;;; Commentary:

;; Load this before the tracked init so warnings from initialization are visible
;; to the batch result instead of being reduced to successful process output.

;;; Code:

(defconst sk/check-sandbox-root
  (file-name-as-directory
   (file-truename
    (or (getenv "SK_EMACS_CHECK_SANDBOX_ROOT")
        (error "SK_EMACS_CHECK_SANDBOX_ROOT is required"))))
  "Only directory where the isolated Emacs process may write.")

(defvar sk/check-warning-records nil
  "Warnings emitted while the isolated batch check is running.")

(defconst sk/check-stale-org-source
  (expand-file-name "stale-native/org.el" sk/check-sandbox-root)
  "Synthetic stale Org source compiled only inside the sandbox.")

(defconst sk/check-stale-org-legacy-cache
  (file-name-as-directory
   (expand-file-name "eln-cache" user-emacs-directory))
  "Legacy native-comp cache populated by the isolated negative fixture.")

(defvar sk/check-stale-org-eln nil
  "Compiled stale Org fixture that the early-init policy must exclude.")

(defconst sk/check-native-comp-eln-load-path-before-early-init
  (copy-sequence native-comp-eln-load-path)
  "Native lookup sequence before the candidate early-init policy runs.")

(defun sk/check-guard-write-path (path)
  "Reject a write to PATH when it escapes `sk/check-sandbox-root'."
  (let ((canonical (file-truename (expand-file-name path))))
    (unless (or (string= (directory-file-name sk/check-sandbox-root)
                         (directory-file-name canonical))
                (string-prefix-p sk/check-sandbox-root canonical))
      (error "batch write escaped sandbox: %s" canonical))))

(defun sk/check-guard-first-path (path &rest _)
  "Guard PATH, the first file argument of a mutating function."
  (sk/check-guard-write-path path))

(defun sk/check-guard-second-path (_source destination &rest _)
  "Guard DESTINATION, the second file argument of a mutating function."
  (sk/check-guard-write-path destination))

(defun sk/check-guard-write-region (_start _end filename &rest _)
  "Guard FILENAME before `write-region' writes the current buffer."
  (sk/check-guard-write-path (or filename buffer-file-name)))

(defun sk/check-record-warning (type message &optional level buffer-name)
  "Record warning TYPE, MESSAGE, LEVEL, and BUFFER-NAME for final validation."
  (unless (eq level :debug)
    (push (list type message level buffer-name) sk/check-warning-records)))

(advice-add #'display-warning :before #'sk/check-record-warning)
(advice-add #'copy-file :before #'sk/check-guard-second-path)
(advice-add #'delete-directory :before #'sk/check-guard-first-path)
(advice-add #'delete-file :before #'sk/check-guard-first-path)
(advice-add #'make-directory :before #'sk/check-guard-first-path)
(advice-add #'make-symbolic-link :before #'sk/check-guard-second-path)
(advice-add #'rename-file :before #'sk/check-guard-second-path)
(advice-add #'set-file-modes :before #'sk/check-guard-first-path)
(advice-add #'write-region :before #'sk/check-guard-write-region)

;; Make the regression causal: a valid native object named org.eln is present
;; in the legacy cache before the copied early-init.el runs.  The final checks
;; establish both that Emacs would find this object if the legacy cache were
;; visible and that the selected profile cache prevents it from being loaded.
(unless (and (fboundp 'native-comp-available-p)
             (native-comp-available-p))
  (error "isolated check requires native compilation"))
(make-directory (file-name-directory sk/check-stale-org-source) t)
(make-directory sk/check-stale-org-legacy-cache t)
(with-temp-file sk/check-stale-org-source
  (insert ";;; org.el --- stale native fixture -*- lexical-binding: t; -*-\n"
          "(defconst sk/check-stale-org-native-code t)\n"
          "(provide 'org)\n"))
(require 'comp)
(let ((output
       (expand-file-name
        (concat comp-native-version-dir "/org.eln")
        sk/check-stale-org-legacy-cache)))
  (make-directory (file-name-directory output) t)
  (setq sk/check-stale-org-eln
        (native-compile sk/check-stale-org-source output)))
(unless (and sk/check-stale-org-eln
             (file-readable-p sk/check-stale-org-eln))
  (error "failed to build stale Org native fixture"))

(when (equal (getenv "SK_EMACS_CHECK_BREAK_WARNING") "1")
  (display-warning 'sk-emacs-check
                   "deliberate warning negative control"
                   :warning))

(setq byte-compile-error-on-warn t)

(provide 'batch-bootstrap)

;;; batch-bootstrap.el ends here
