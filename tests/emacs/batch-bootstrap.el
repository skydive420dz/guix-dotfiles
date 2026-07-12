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

(when (equal (getenv "SK_EMACS_CHECK_BREAK_WARNING") "1")
  (display-warning 'sk-emacs-check
                   "deliberate warning negative control"
                   :warning))

(setq byte-compile-error-on-warn t)

(provide 'batch-bootstrap)

;;; batch-bootstrap.el ends here
