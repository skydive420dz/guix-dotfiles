;;; sk-completion.el --- Completion, help, and discovery -*- lexical-binding: t; -*-

;; Minibuffer completion:
;; Ivy/Counsel own command selection, file finding, buffer switching, and search
;; prompts.  This is separate from in-buffer code completion, which Company owns
;; in sk-lsp.el.
(use-package ivy
  :diminish
  :bind (("C-s" . swiper)
         :map ivy-minibuffer-map
         ("TAB" . ivy-alt-done)
         ("C-l" . ivy-alt-done)
         ("C-j" . ivy-next-line)
         ("C-k" . ivy-previous-line)
         :map ivy-switch-buffer-map
         ("C-k" . ivy-previous-line)
         ("C-l" . ivy-done)
         ("C-d" . ivy-switch-buffer-kill)
         :map ivy-reverse-i-search-map
         ("C-k" . ivy-previous-line)
         ("C-d" . ivy-reverse-i-search-kill))
  :config
  ;; Ivy defaults `counsel-M-x' to an initial "^", which makes command
  ;; discovery prefix-only.  M-x should find commands containing the text typed.
  (setq ivy-initial-inputs-alist
        (assq-delete-all 'counsel-M-x ivy-initial-inputs-alist))
  (setq ivy-re-builders-alist
        '((counsel-M-x . ivy--regex-ignore-order)
          (counsel-switch-buffer . ivy--regex-ignore-order)
          (counsel-ibuffer . ivy--regex-ignore-order)
          (t . ivy--regex-plus)))
  (ivy-mode 1))

(use-package which-key
  :init (which-key-mode)
  :diminish which-key-mode
  :config
  (setq which-key-idle-delay 0.35
        which-key-idle-secondary-delay 0.35
        which-key-popup-type 'side-window
        which-key-side-window-location 'bottom
        which-key-side-window-max-height 0.25
        which-key-sort-order #'which-key-key-order-alpha))

;; Snippet engine:
;; lsp-mode advertises snippet-capable completions by default.  Yasnippet is the
;; provider that expands those snippets when a language server returns them.
;; This tracked directory is the sole authored-snippet source; package-provided
;; LSP snippets still arrive dynamically through Company.
(defconst sk/snippets-directory
  (expand-file-name "snippets" sk/user-directory)
  "Repository-owned Yasnippet directory for the GuixPC editor.")

(defconst sk/authored-snippet-contract
  '((emacs-lisp-mode "ERT test" "ert")
    (scheme-mode "Guile procedure" "define")
    (lisp-mode "Common Lisp function" "defun")
    (org-mode "Org source block" "src"))
  "Reviewed authored snippets as (MODE NAME KEY) triples.")

(use-package yasnippet
  :if (locate-library "yasnippet")
  :init
  (setq yas-snippet-dirs (list sk/snippets-directory))
  :config
  (yas-global-mode 1)
  ;; Global mode prepares lazy tables; finish with an eager load so startup and
  ;; the live checker can prove the exact authored inventory immediately.
  (yas-reload-all t))

;; Better minibuffer annotations for Ivy results.
(use-package ivy-rich
  :after ivy
  :config
  (ivy-rich-set-columns
   'counsel-M-x
   '((counsel-M-x-transformer (:width 36))
     (ivy-rich-counsel-function-docstring (:face font-lock-doc-face))))
  (ivy-rich-set-columns
   'counsel-describe-function
   '((counsel-describe-function-transformer (:width 36))
     (ivy-rich-counsel-function-docstring (:face font-lock-doc-face))))
  (ivy-rich-set-columns
   'counsel-describe-variable
   '((counsel-describe-variable-transformer (:width 36))
     (ivy-rich-counsel-variable-docstring (:face font-lock-doc-face))))
  (ivy-rich-mode 1))

;; Counsel supplies Ivy-backed replacements for common Emacs commands.
(use-package counsel
  :bind (("M-x" . counsel-M-x)
         ("C-x b" . counsel-ibuffer)
         ("C-x C-f" . counsel-find-file)
         :map minibuffer-local-map
         ("C-r" . counsel-minibuffer-history))
  :config
  ;; Counsel installs its own "^" default after Ivy loads.  Remove it here so
  ;; M-x remains contains/ignore-order search instead of prefix-only search.
  (setq ivy-initial-inputs-alist
        (assq-delete-all 'counsel-M-x ivy-initial-inputs-alist)))

;; Helpful is the richer documentation UI for Emacs Lisp symbols and keys.
(use-package helpful
  :custom
  (counsel-describe-function-function #'helpful-callable)
  (counsel-describe-variable-function #'helpful-variable)
  :bind
  ([remap describe-function] . counsel-describe-function)
  ([remap describe-command] . helpful-command)
  ([remap describe-variable] . counsel-describe-variable)
  ([remap describe-key] . helpful-key))

(provide 'sk-completion)

;;; sk-completion.el ends here
