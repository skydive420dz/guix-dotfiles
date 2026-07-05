;;; sk-json.el --- JSON editing setup -*- lexical-binding: t; -*-

;; JSON is not LSP-backed here:
;; Guix does not currently provide a clean JSON language-server package.  This
;; slice uses json-mode for editing and Flycheck's JSON checkers for validation.
(use-package json-mode
  :if (locate-library "json-mode")
  :mode (("\\.json\\'" . json-mode)
         ("\\.jsonc\\'" . json-mode))
  :hook (json-mode . flycheck-mode)
  :custom
  (js-indent-level 2)
  (json-reformat:indent-width 2))

;; Tool ownership:
;; jq is already installed system-wide and is one of Flycheck's JSON checker
;; options.  Formatting is intentionally not bound here yet.
(with-eval-after-load 'flycheck
  (setq flycheck-json-jq-executable "jq"))

(provide 'sk-json)

;;; sk-json.el ends here
