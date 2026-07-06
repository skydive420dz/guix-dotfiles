;;; sk-c.el --- C editing setup -*- lexical-binding: t; -*-

;; C is LSP-backed through clangd:
;; cc-mode/c-mode owns syntax and indentation, while lsp-mode starts clangd for
;; completion, hover, references, diagnostics, and symbol navigation.
(use-package cc-mode
  :ensure nil
  :mode (("\\.c\\'" . c-mode)
         ("\\.h\\'" . c-mode))
  :hook (c-mode . lsp-deferred)
  :custom
  (c-basic-offset 4))

;; clangd policy:
;; clangd and clang-format come from the Guix clang package.  clang-format is
;; available for the formatting contract, but this file does not bind format
;; keys or force format-on-save behavior.
(with-eval-after-load 'lsp-mode
  (setq lsp-clients-clangd-executable "clangd"))

(provide 'sk-c)

;;; sk-c.el ends here
