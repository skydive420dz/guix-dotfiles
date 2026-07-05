;;; sk-lua.el --- Lua editing setup -*- lexical-binding: t; -*-

(use-package lua-mode
  :if (locate-library "lua-mode")
  :mode "\\.lua\\'"
  :hook (lua-mode . lsp-deferred))

(with-eval-after-load 'lsp-mode
  (setq lsp-clients-lua-language-server-command '("lua-language-server")
        lsp-lua-telemetry-enable nil))

(provide 'sk-lua)

;;; sk-lua.el ends here
