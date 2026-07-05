;;; Generated state

(defvar sk/cache-directory
  (expand-file-name "emacs/" (or (getenv "XDG_CACHE_HOME") "~/.cache/"))
  "Directory for generated Emacs state.")

(make-directory sk/cache-directory t)
(dolist (directory '("backups" "auto-save" "auto-save-list"))
  (make-directory (expand-file-name directory sk/cache-directory) t))

;;; History

(setq recentf-save-file
      (expand-file-name "recentf" sk/cache-directory)
      savehist-file
      (expand-file-name "savehist" sk/cache-directory)
      save-place-file
      (expand-file-name "saveplace" sk/cache-directory))

(recentf-mode 1)
(savehist-mode 1)
(save-place-mode 1)

(setq backup-directory-alist
      `(("." . ,(expand-file-name "backups/" sk/cache-directory)))
      auto-save-file-name-transforms
      `((".*" ,(expand-file-name "auto-save/" sk/cache-directory) t))
      auto-save-list-file-prefix
      (expand-file-name "auto-save-list/.saves-" sk/cache-directory)
      create-lockfiles nil)

;;; Global entry points

(global-set-key (kbd "C-c e") #'eshell) ; launch eshell
(global-set-key (kbd "C-c t") #'term) ; launch term

;;; Server

(require 'server)
(unless (server-running-p)
  (server-start))

;;; Editing defaults

(delete-selection-mode 1)
(global-auto-revert-mode 1)
(show-paren-mode 1)
(setq show-paren-delay 0)
(setq-default indent-tabs-mode nil)
(setq-default tab-width 4)
(setq require-final-newline t)

(setq visible-bell t) ; setup visual bell
(electric-pair-mode 1) ; automatically insert matching parens, brackets, and quotes

(use-package rainbow-delimiters
  :hook (prog-mode . rainbow-delimiters-mode))

;;; Package setup

;; Emacs packages are installed by Guix. This file only wires behavior.
(require 'use-package)

(defvar sk/user-directory
  (file-name-directory
   (file-truename (or load-file-name buffer-file-name user-init-file)))
  "Root directory of this Emacs configuration.")

(defvar sk/lisp-directory
  (expand-file-name "lisp" sk/user-directory)
  "Directory for personal Emacs modules.")

(add-to-list 'load-path sk/lisp-directory)

(require 'sk-ui)

;;; Completion and minibuffer

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
  (ivy-mode 1))

;;; Discoverability

(use-package which-key
  :init (which-key-mode)
  :diminish which-key-mode
  :config
  (setq which-key-idle-delay 1))

(use-package ivy-rich
  :after ivy
  :config
  (ivy-rich-mode 1))

;;; Commands and help

(use-package counsel
  :bind (("M-x" . counsel-M-x)
	 ("C-x b" . counsel-ibuffer)
	 ("C-x C-f" . counsel-find-file)
	 :map minibuffer-local-map
	 ("C-r" . counsel-minibuffer-history)))

(use-package helpful
  :custom
  (counsel-describe-function-function #'helpful-callable)
  (counsel-describe-variable-function #'helpful-variable)
  :bind
  ([remap describe-function] . counsel-describe-function)
  ([remap describe-command] . helpful-command)
  ([remap describe-variable] . counsel-describe-variable)
  ([remap describe-key] . helpful-key))

;;; Leader keys

(use-package general
  :config
  (general-create-definer rune/leader-keys
    :keymaps '(normal insert visual emacs)
    :prefix "SPC"
    :global-prefix "C-SPC")

  (rune/leader-keys
    "t"  '(:ignore t :which-key "toggles")
    "tt" '(counsel-load-theme :which-key "choose theme")))

;;; Evil

(use-package evil
  :init
  (setq evil-undo-system 'undo-redo)
  (setq evil-want-integration t)
  (setq evil-want-keybinding nil)
  (setq evil-want-C-u-scroll t)
  (setq evil-want-C-i-jump nil)
  :config
  (evil-mode 1)
  (define-key evil-insert-state-map (kbd "C-g") 'evil-normal-state)
  (define-key evil-insert-state-map (kbd "C-h") 'evil-delete-backward-char-and-join)

  ;; Use visual line motions even outside of visual-line-mode buffers
  (evil-global-set-key 'motion "j" 'evil-next-visual-line)
  (evil-global-set-key 'motion "k" 'evil-previous-visual-line)

  (evil-set-initial-state 'messages-buffer-mode 'normal)
  (evil-set-initial-state 'dashboard-mode 'normal))

(use-package evil-collection
  :after evil
  :config
  (evil-collection-init))

;;; Window management

(winner-mode 1)

;;; Projects and Git

(use-package projectile
  :diminish projectile-mode
  :config (projectile-mode)
  :custom ((projectile-completion-system 'ivy))
  :bind-keymap
  ("C-c p" . projectile-command-map)
  :init
  ;; NOTE: Set this to the folder where you keep your Git repos!
  (when (file-directory-p "~/Projects/guix-dotfiles")
    (setq projectile-project-search-path '("~/Projects/guix-dotfiles")))
  (setq projectile-switch-project-action #'projectile-dired))

(use-package counsel-projectile
  :config (counsel-projectile-mode))

(use-package magit
  :custom
  (magit-display-buffer-function #'magit-display-buffer-same-window-except-diff-v1))

;;; LSP & Language Servers

(use-package lsp-mode
  :commands (lsp lsp-deferred)
  :init
  (setq lsp-keymap-prefix "C-c l")
  :config
  (lsp-enable-which-key-integration t))

;; if you are ivy user
(use-package lsp-ivy :commands lsp-ivy-workspace-symbol)
(use-package lsp-treemacs :commands lsp-treemacs-errors-list)

;;; Org and notes

(require 'sk-org)
(require 'sk-notes)
