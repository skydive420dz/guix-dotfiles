;;; early-init-visual-check.el --- Pre-frame visual policy checks -*- lexical-binding: t; -*-

;;; Commentary:

;; This file is loaded immediately after the tracked early-init and before
;; init.el.  Keeping this boundary explicit prevents a late init mutation from
;; falsely satisfying creation-time frame assertions.

;;; Code:

(require 'cl-lib)

(defconst sk/check-expected-early-frame-parameters
  '((menu-bar-lines . 0)
    (tool-bar-lines . 0)
    (vertical-scroll-bars . nil)
    (horizontal-scroll-bars . nil)
    (left-fringe . 10)
    (right-fringe . 10)
    (fullscreen . fullboth)
    (undecorated . t))
  "Exact creation-time frame policy expected before init.el.")

(unless inhibit-startup-message
  (error "early-init did not inhibit the startup message"))
(unless inhibit-startup-screen
  (error "early-init did not inhibit the startup screen"))
(unless (equal sk/early-frame-parameters
               sk/check-expected-early-frame-parameters)
  (error "early-init frame contract drifted: %S"
         sk/early-frame-parameters))

(dolist (entry sk/check-expected-early-frame-parameters)
  (dolist (alist-symbol '(initial-frame-alist default-frame-alist))
    (let* ((parameter (car entry))
           (expected (cdr entry))
           (alist (symbol-value alist-symbol))
           (matches (cl-count parameter alist :key #'car :test #'eq))
           (actual-entry (assq parameter alist)))
      (unless (= matches 1)
        (error "%S has %d owners for %S"
               alist-symbol matches parameter))
      (unless (and actual-entry
                   (equal (cdr actual-entry) expected))
        (error "%S has wrong early value for %S: %S"
               alist-symbol parameter actual-entry)))))

(unless (and (boundp 'sk/theme-generated-file)
             (fboundp 'sk/immutable-store-file-p)
             (fboundp 'sk/load-generated-theme))
  (error "early-init does not own immutable generated-theme loading"))
(when (featurep 'sk-theme-generated)
  (error "adapter unexpectedly loaded in the empty preactivation fixture"))
(when (file-readable-p sk/theme-generated-file)
  (error "preactivation fixture unexpectedly exposes a theme adapter"))

(provide 'early-init-visual-check)

;;; early-init-visual-check.el ends here
