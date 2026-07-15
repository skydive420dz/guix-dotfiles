;;; sk-lsp.el --- Language server setup -*- lexical-binding: t; -*-

;; `use-package' autoloads the public `lsp' entry point in clean -Q sessions,
;; but that path does not load lsp-mode-autoloads.el.  Pinned lsp-mode 10.0.0
;; installs the following private functions on configure hooks before their
;; implementation libraries are loaded.  Recreate its reviewed lazy boundary
;; so an explicitly started server cannot log void-function errors; this does
;; not load lsp-mode or start a process on the cold editing path.
(autoload 'lsp-headerline-breadcrumb-mode "lsp-headerline" nil t)
(autoload 'lsp-lens--enable "lsp-lens" nil nil)
(autoload 'lsp-modeline-code-actions-mode "lsp-modeline" nil t)
(autoload 'lsp-modeline-diagnostics-mode "lsp-modeline" nil t)
(autoload 'lsp-modeline-workspace-status-mode "lsp-modeline" nil t)
(autoload 'lsp-semantic-tokens--enable "lsp-semantic-tokens" nil nil)

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
  (company-backends
   '((company-capf company-yasnippet)
     company-files
     company-keywords
     company-dabbrev-code))
  :bind (:map company-active-map
              ("C-j" . company-select-next)
              ("C-k" . company-select-previous)
              ("C-l" . company-complete-selection)
              ("C-h" . company-abort)))

;; Diagnostics frontend:
;; Flycheck renders errors/warnings.  lsp-mode can publish diagnostics into it
;; for LSP buffers, and non-LSP modes can use their own Flycheck checkers.
;; The compatibility filter below updates Flycheck error structs through their
;; generated `setf' accessors, so make those accessors available to both the
;; interpreter and the byte/native compiler.  Flycheck itself is already an
;; eager `use-package' dependency here; this does not load Org.
(eval-and-compile
  (when (locate-library "flycheck")
    (require 'flycheck)))

(defun sk/flycheck--org-lint-line-number (line)
  "Return LINE as a positive Org lint line number, or nil.

Org 9.8 may return a propertized decimal string carrying an
`org-lint-marker' property, while Flycheck 36 later sorts lint errors by a
numeric line field.  Preserve positive integers and normalize only positive
decimal strings; malformed protocol values remain explicit failures."
  (cond
   ((and (integerp line) (> line 0)) line)
   ((stringp line)
    (let ((plain-line (substring-no-properties line)))
      (when (string-match-p "\\`[0-9]+\\'" plain-line)
        (let ((number (string-to-number plain-line)))
          (and (> number 0) number)))))))

(defun sk/flycheck-org-lint-filter (errors)
  "Normalize Org 9.8 line fields in Flycheck ERRORS.

Valid fields become integers before Flycheck sorts them.  Turn any malformed
field into an explicit line-one warning instead of silently relocating the
original finding.  Finally apply Flycheck's normal error sanitization."
  (dolist (lint-error errors)
    (let* ((line (flycheck-error-line lint-error))
           (number (sk/flycheck--org-lint-line-number line)))
      (if number
          (setf (flycheck-error-line lint-error) number)
        (setf (flycheck-error-line lint-error) 1
              (flycheck-error-level lint-error) 'warning
              (flycheck-error-message lint-error)
              (format "Unexpected org-lint line %S: %s"
                      line
                      (or (flycheck-error-message lint-error)
                          "no message"))))))
  (flycheck-sanitize-errors errors))

(use-package flycheck
  :if (locate-library "flycheck")
  :hook ((after-init . global-flycheck-mode)
         (lsp-mode . flycheck-mode))
  :config
  ;; Flycheck 36 assumes that `org-lint' always returns a numeric line field,
  ;; while Org 9.8 returns a propertized string.  Preserve a downstream or
  ;; future backport if it already supplied a checker-specific filter.
  (when (and (equal flycheck-version "36.0")
             (memq (flycheck-checker-get 'org-lint 'error-filter)
                   '(nil identity)))
    (setf (flycheck-checker-get 'org-lint 'error-filter)
          #'sk/flycheck-org-lint-filter)))

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
        lsp-diagnostics-provider :auto
        lsp-headerline-breadcrumb-enable t
        lsp-headerline-breadcrumb-icons-enable t
        lsp-headerline-breadcrumb-enable-diagnostics t
        lsp-headerline-breadcrumb-segments '(path-up-to-project file symbols))
  :hook (lsp-mode . lsp-enable-which-key-integration))

;; LSP visual layer:
;; lsp-ui owns popup hover docs, sideline diagnostics, and code-action hints for
;; languages that are actually running through lsp-mode.
(use-package lsp-ui
  :if (locate-library "lsp-ui")
  :commands lsp-ui-mode
  :hook (lsp-mode . lsp-ui-mode)
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

(defun sk/code-action ()
  "Run a code action for the current LSP buffer."
  (interactive)
  (if (and (bound-and-true-p lsp-mode)
           (fboundp 'lsp-execute-code-action))
      (call-interactively #'lsp-execute-code-action)
    (user-error "Code actions require an active LSP buffer")))

(defun sk/code-docs ()
  "Show documentation for the symbol at point when the backend provides it."
  (interactive)
  (cond
   ((and (bound-and-true-p lsp-mode)
         (fboundp 'lsp-ui-doc-show))
    (lsp-ui-doc-show))
   ((and (bound-and-true-p lsp-mode)
         (fboundp 'lsp-describe-thing-at-point))
    (lsp-describe-thing-at-point))
   ((fboundp 'eldoc-print-current-symbol-info)
    (eldoc-print-current-symbol-info))
   (t
    (user-error "No documentation backend is active in this buffer"))))

(defun sk/code-rename ()
  "Rename the symbol at point through the active LSP backend."
  (interactive)
  (if (and (bound-and-true-p lsp-mode)
           (fboundp 'lsp-rename))
      (call-interactively #'lsp-rename)
    (user-error "Rename requires an active LSP buffer")))

(defun sk/code-definition ()
  "Jump to the definition at point."
  (interactive)
  (let ((symbol (thing-at-point 'symbol t)))
    (if symbol
        (xref-find-definitions symbol)
      (user-error "No symbol at point"))))

(defun sk/code-references ()
  "Show references for the symbol at point."
  (interactive)
  (let ((symbol (thing-at-point 'symbol t)))
    (if symbol
        (xref-find-references symbol)
      (user-error "No symbol at point"))))

(defun sk/code-implementation ()
  "Jump to implementation for the current LSP symbol."
  (interactive)
  (if (and (bound-and-true-p lsp-mode)
           (fboundp 'lsp-find-implementation))
      (lsp-find-implementation)
    (user-error "Implementation lookup requires an active LSP buffer")))

(defun sk/code-type-definition ()
  "Jump to type definition for the current LSP symbol."
  (interactive)
  (if (and (bound-and-true-p lsp-mode)
           (fboundp 'lsp-find-type-definition))
      (lsp-find-type-definition)
    (user-error "Type definition lookup requires an active LSP buffer")))

(defun sk/code-symbols ()
  "Open the LSP document symbol tree for the current buffer."
  (interactive)
  (if (and (bound-and-true-p lsp-mode)
           (fboundp 'lsp-treemacs-symbols))
      (lsp-treemacs-symbols)
    (user-error "Symbol tree requires an active LSP buffer")))

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
    (let ((deadline (+ (float-time) 2)))
      (while (and (< (float-time) deadline)
                  (boundp 'flycheck-is-checking)
                  flycheck-is-checking)
        (accept-process-output nil 0.05)))
    (flycheck-list-errors))
   (t
    (user-error "No diagnostics backend is active in this buffer"))))

(provide 'sk-lsp)

;;; sk-lsp.el ends here
