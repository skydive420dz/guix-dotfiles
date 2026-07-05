;;; sk-python.el --- Python editing setup -*- lexical-binding: t; -*-

;; Python is LSP-backed through python-lsp-server (pylsp):
;; python-mode owns indentation/syntax, while lsp-mode starts pylsp for
;; completion, hover, references, and diagnostics.
(use-package python
  :ensure nil
  :mode ("\\.py\\'" . python-mode)
  :hook (python-mode . lsp-deferred)
  :custom
  (python-shell-interpreter "python3")
  (python-indent-offset 4))

;; pylsp plugin policy:
;; Jedi supplies semantic completion/hover/references/signatures.  Pyflakes and
;; flake8 supply diagnostics.  Formatting is intentionally not owned here yet.
(with-eval-after-load 'lsp-mode
  (setq lsp-pylsp-server-command '("pylsp")
        lsp-pylsp-configuration-sources ["flake8"]
        lsp-pylsp-plugins-jedi-completion-enabled t
        lsp-pylsp-plugins-jedi-hover-enabled t
        lsp-pylsp-plugins-jedi-references-enabled t
        lsp-pylsp-plugins-jedi-signature-help-enabled t
        lsp-pylsp-plugins-pyflakes-enabled t
        lsp-pylsp-plugins-flake8-enabled t))

(provide 'sk-python)

;;; sk-python.el ends here
