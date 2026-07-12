;;; sk-json.el --- JSON editing setup -*- lexical-binding: t; -*-

;; JSON is not LSP-backed here.  Strict JSON uses jq for validation, while
;; JSONC uses jsonc-mode's comment-aware syntax and deliberately has no
;; Flycheck checker: the installed JSON checkers reject comments.  JSONC
;; formatting is handled separately in sk-format.el.
(declare-function flycheck-mode "flycheck" (&optional argument))
(defvar flycheck-checker)
(defvar flycheck-json-jq-executable)

(defun sk/json-configure-validation ()
  "Apply the strict JSON or comment-aware JSONC validation policy."
  (when (fboundp 'flycheck-mode)
    (if (derived-mode-p 'jsonc-mode)
        (progn
          (setq-local flycheck-checker nil)
          (when (bound-and-true-p flycheck-mode)
            (flycheck-mode -1)))
      (setq-local flycheck-checker 'json-jq)
      (flycheck-mode 1))))

(defun sk/json-keep-jsonc-flycheck-disabled ()
  "Turn Flycheck back off when its global mode reaches a JSONC buffer."
  (when (and (bound-and-true-p flycheck-mode)
             (derived-mode-p 'jsonc-mode))
    (flycheck-mode -1)))

(use-package json-mode
  :if (locate-library "json-mode")
  :mode (("\\.json\\'" . json-mode)
         ("\\.jsonc\\'" . jsonc-mode))
  :hook ((json-mode . sk/json-configure-validation)
         (jsonc-mode . sk/json-configure-validation))
  :custom
  (js-indent-level 2)
  (json-reformat:indent-width 2))

;; Fallback for the built-in JSON mode used when json-mode is unavailable in the
;; current Emacs session, such as before restarting after a Guix reconfigure.
(add-hook 'js-json-mode-hook #'sk/json-configure-validation)

;; Tool ownership:
;; jq is installed system-wide.  Prefer it over Flycheck's python checker because
;; this Guix profile exposes python3, while that checker looks for python.
(with-eval-after-load 'flycheck
  (setq flycheck-json-jq-executable "jq")
  (add-hook 'flycheck-mode-hook #'sk/json-keep-jsonc-flycheck-disabled))

(provide 'sk-json)

;;; sk-json.el ends here
