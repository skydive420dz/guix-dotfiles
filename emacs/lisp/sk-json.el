;;; sk-json.el --- JSON editing setup -*- lexical-binding: t; -*-

;; JSON is not LSP-backed here:
;; Guix does not currently provide a clean JSON language-server package.  This
;; slice uses json-mode when available, the built-in js-json-mode fallback when
;; needed, and Flycheck's jq checker for validation.
(defun sk/json-enable-flycheck ()
  "Enable JSON validation with jq in the current buffer."
  (when (fboundp 'flycheck-mode)
    (setq-local flycheck-checker 'json-jq)
    (flycheck-mode 1)))

(use-package json-mode
  :if (locate-library "json-mode")
  :mode (("\\.json\\'" . json-mode)
         ("\\.jsonc\\'" . json-mode))
  :hook (json-mode . sk/json-enable-flycheck)
  :custom
  (js-indent-level 2)
  (json-reformat:indent-width 2))

;; Fallback for the built-in JSON mode used when json-mode is unavailable in the
;; current Emacs session, such as before restarting after a Guix reconfigure.
(add-hook 'js-json-mode-hook #'sk/json-enable-flycheck)

;; Tool ownership:
;; jq is installed system-wide.  Prefer it over Flycheck's python checker because
;; this Guix profile exposes python3, while that checker looks for python.
;; Formatting is intentionally not bound here yet.
(with-eval-after-load 'flycheck
  (setq flycheck-json-jq-executable "jq"))

(provide 'sk-json)

;;; sk-json.el ends here
