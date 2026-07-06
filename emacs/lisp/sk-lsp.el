;;; sk-lsp.el --- Language server setup -*- lexical-binding: t; -*-

;; In-buffer completion frontend:
;; Company displays completion candidates.  Language servers feed it through
;; completion-at-point via lsp-mode, while non-LSP modes can still use Company.
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

;; Diagnostics frontend:
;; Flycheck renders errors/warnings.  lsp-mode can publish diagnostics into it
;; for LSP buffers, and non-LSP modes can use their own Flycheck checkers.
(use-package flycheck
  :if (locate-library "flycheck"))

;; LSP client:
;; This is the shared backend for external language servers.  Root guessing is
;; enabled so standalone study files outside a project still get LSP features.
(use-package lsp-mode
  :commands (lsp lsp-deferred)
  :init
  (setq lsp-keymap-prefix "C-c l"
        lsp-auto-guess-root t
        lsp-guess-root-without-session t
        lsp-completion-provider :capf
        lsp-completion-show-detail t
        lsp-completion-show-kind t
        lsp-completion-use-last-result t
        lsp-diagnostics-provider :auto)
  :hook (lsp-mode . lsp-enable-which-key-integration))

;; LSP visual layer:
;; lsp-ui owns popup hover docs, sideline diagnostics, and code-action hints for
;; languages that are actually running through lsp-mode.
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

;; Workspace symbol search for LSP-backed languages.
(use-package lsp-ivy
  :commands lsp-ivy-workspace-symbol)

;; Tree/list views for LSP diagnostics and related result buffers.
(use-package lsp-treemacs
  :commands lsp-treemacs-errors-list)

(defun sk/code-diagnostics ()
  "Open diagnostics for the current buffer.

Prefer the LSP diagnostics UI when the current buffer is LSP-backed.  Fall back
to Flycheck's error list for non-LSP buffers such as JSON and shell scripts."
  (interactive)
  (cond
   ((and (bound-and-true-p lsp-mode)
         (fboundp 'lsp-treemacs-errors-list))
    (lsp-treemacs-errors-list))
   ((and (bound-and-true-p flycheck-mode)
         (fboundp 'flycheck-list-errors))
    (flycheck-buffer)
    (flycheck-list-errors))
   (t
    (user-error "No diagnostics backend is active in this buffer"))))

(provide 'sk-lsp)

;;; sk-lsp.el ends here
