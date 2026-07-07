;;; sk-lua.el --- Lua editing setup -*- lexical-binding: t; -*-

;; Lua is a normal LSP-backed language here:
;; lua-mode owns the major mode, and lsp-mode starts lua-language-server.
(use-package lua-mode
  :if (locate-library "lua-mode")
  :mode "\\.lua\\'"
  :hook (lua-mode . lsp-deferred)
  :custom
  (lua-indent-level 2))

;; Server-specific settings only.  Keep shared completion/docs/diagnostics in
;; sk-lsp.el so Lua follows the same global LSP behavior as Python.
(with-eval-after-load 'lsp-mode
  (setq lsp-clients-lua-language-server-command '("lua-language-server")
        lsp-lua-telemetry-enable nil))

(provide 'sk-lua)

;;; sk-lua.el ends here
