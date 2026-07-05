;;; sk-lsp.el --- Language server setup -*- lexical-binding: t; -*-

(use-package company
  :if (locate-library "company")
  :hook (after-init . global-company-mode)
  :custom
  (company-idle-delay 0.15)
  (company-minimum-prefix-length 1)
  (company-selection-wrap-around t)
  (company-tooltip-align-annotations t)
  :bind (:map company-active-map
              ("C-j" . company-select-next)
              ("C-k" . company-select-previous)
              ("C-l" . company-complete-selection)
              ("C-h" . company-abort)))

(use-package flycheck
  :if (locate-library "flycheck"))

(use-package lsp-mode
  :commands (lsp lsp-deferred)
  :init
  (setq lsp-keymap-prefix "C-c l"
        lsp-completion-provider :capf
        lsp-completion-show-detail t
        lsp-completion-show-kind t
        lsp-completion-use-last-result t
        lsp-diagnostics-provider :auto)
  :hook (lsp-mode . lsp-enable-which-key-integration))

(use-package lsp-ui
  :if (locate-library "lsp-ui")
  :commands lsp-ui-mode
  :custom
  (lsp-ui-doc-enable t)
  (lsp-ui-doc-show-with-cursor t)
  (lsp-ui-doc-show-with-mouse nil)
  (lsp-ui-doc-delay 0.35)
  (lsp-ui-doc-position 'at-point)
  (lsp-ui-sideline-show-diagnostics t)
  (lsp-ui-sideline-show-code-actions t)
  (lsp-ui-sideline-show-hover nil)
  (lsp-ui-sideline-delay 0.35))

(use-package lsp-ivy
  :commands lsp-ivy-workspace-symbol)

(use-package lsp-treemacs
  :commands lsp-treemacs-errors-list)

(provide 'sk-lsp)

;;; sk-lsp.el ends here
