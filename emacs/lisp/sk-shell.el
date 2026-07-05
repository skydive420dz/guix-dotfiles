;;; sk-shell.el --- Shell script editing setup -*- lexical-binding: t; -*-

;; Shell scripts are not LSP-backed here:
;; Guix does not currently provide bash-language-server, so this slice uses
;; Emacs' built-in sh-mode plus Flycheck/ShellCheck diagnostics.
(use-package sh-script
  :ensure nil
  :mode (("\\.sh\\'" . sh-mode)
         ("\\.bash\\'" . sh-mode)
         ("\\.env\\'" . sh-mode))
  :hook (sh-mode . flycheck-mode)
  :custom
  (sh-basic-offset 2)
  (sh-indentation 2))

;; Tool ownership:
;; Flycheck runs the shell syntax checker first, then chains warnings to
;; shellcheck.  shfmt is installed system-wide for the future formatting
;; contract, but this file does not bind formatting keys yet.
(with-eval-after-load 'flycheck
  (setq flycheck-sh-shellcheck-executable "shellcheck"))

(provide 'sk-shell)

;;; sk-shell.el ends here
