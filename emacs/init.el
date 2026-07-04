;;; Startup and frame defaults

(setq inhibit-startup-message t)

(scroll-bar-mode -1) ; hides the scrollbar
(tool-bar-mode -1) ; disable the toolbar
(tooltip-mode -1) ; disable tooltips
(set-fringe-mode 10) ; gives some breathing room

(menu-bar-mode -1) ; disable menu bar

;;; Global entry points

(global-set-key (kbd "C-c e") #'eshell) ; launch eshell
(global-set-key (kbd "C-c t") #'term) ; launch term

;;; Server

(require 'server)
(unless (server-running-p)
  (server-start))

;;; Editing defaults

(setq visible-bell t) ; setup visual bell

(use-package rainbow-delimiters
  :hook (prog-mode . rainbow-delimiters-mode))

(column-number-mode)
(global-display-line-numbers-mode t)

;; Disable line numbers for some modes.
(dolist (mode '(org-mode-hook
                term-mode-hook
                shell-mode-hook
                eshell-mode-hook))
  (add-hook mode (lambda () (display-line-numbers-mode 0))))

;;; Fonts and theme

(set-face-attribute 'default nil :family "Iosevka Term" :height 120) ; setup font face
(set-fontset-font t 'symbol "Symbols Nerd Font Mono" nil 'append)

(load-theme 'modus-vivendi-tinted) ; setup theme

;;; Package setup

;; Emacs packages are installed by Guix. This file only wires behavior.
(require 'use-package)

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

;;; Modeline

(use-package doom-modeline
  :config
  (doom-modeline-mode 1))

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

;;; Org mode setup

(defun efs/org-mode-setup ()
  (org-indent-mode)
  (variable-pitch-mode 1)
  (visual-line-mode 1))

;;; Org paths and note helpers

(defvar sk/org-directory (expand-file-name "~/Documents/OrgFiles"))
(defvar sk/org-daily-directory (expand-file-name "Daily" sk/org-directory))
(defvar sk/org-weekly-directory (expand-file-name "Weekly" sk/org-directory))
(defvar sk/org-template-directory (expand-file-name "Templates" sk/org-directory))
(defvar sk/org-daily-template-file
  (expand-file-name "Daily.org" sk/org-template-directory))
(defvar sk/org-weekly-template-file
  (expand-file-name "Weekly.org" sk/org-template-directory))

(defun sk/read-file-as-string (file)
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defun sk/org-daily-file (&optional time)
  (expand-file-name
   (format-time-string "%Y-%m-%d.org" time)
   sk/org-daily-directory))

(defun sk/org-weekly-file (&optional time)
  (expand-file-name
   (format-time-string "%G-W%V.org" time)
   sk/org-weekly-directory))

(defun sk/org-daily-template (&optional time)
  (let* ((time (or time (current-time)))
         (date (format-time-string "%Y-%m-%d" time))
         (weekday (format-time-string "%A" time))
         (template (or (sk/read-file-as-string sk/org-daily-template-file)
                       "#+title: {{date}}\n#+date: {{date}}\n\n* Plan\n\n* Log\n\n* Notes\n\n* Review\n")))
    (setq template (replace-regexp-in-string "{{date}}" date template t t))
    (setq template (replace-regexp-in-string "{{weekday}}" weekday template t t))
    template))

(defun sk/org-weekly-template (&optional time)
  (let* ((time (or time (current-time)))
         (week (format-time-string "%G-W%V" time))
         (date (format-time-string "%Y-%m-%d" time))
         (template (or (sk/read-file-as-string sk/org-weekly-template-file)
                       "#+title: {{week}}\n#+date: {{date}}\n\n* Review\n\n* Plan\n")))
    (setq template (replace-regexp-in-string "{{week}}" week template t t))
    (setq template (replace-regexp-in-string "{{date}}" date template t t))
    template))

(defun sk/org-ensure-daily-note (&optional time)
  (let ((file (sk/org-daily-file time)))
    (make-directory (file-name-directory file) t)
    (unless (file-exists-p file)
      (with-temp-file file
        (insert (sk/org-daily-template time))))
    file))

(defun sk/org-ensure-weekly-note (&optional time)
  (let ((file (sk/org-weekly-file time)))
    (make-directory (file-name-directory file) t)
    (unless (file-exists-p file)
      (with-temp-file file
        (insert (sk/org-weekly-template time))))
    file))

(defun sk/org-open-daily-note ()
  (interactive)
  (find-file (sk/org-ensure-daily-note)))

(defun sk/org-open-weekly-note ()
  (interactive)
  (find-file (sk/org-ensure-weekly-note)))

(defun sk/org-daily-capture-target ()
  (let ((file (sk/org-ensure-daily-note)))
    (set-buffer (org-capture-target-buffer file))
    (goto-char (point-min))
    (unless (re-search-forward "^\\* Inbox" nil t)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert "\n* Inbox\n"))
    (forward-line 1)
    (let ((end (save-excursion
                 (if (re-search-forward "^\\* " nil t)
                     (match-beginning 0)
                   (point-max)))))
      (goto-char end))
    (cond
     ((not (bolp)) (insert "\n"))
     ((save-excursion
        (forward-line -1)
        (looking-at-p "^$"))
      (forward-line -1))
     (t (insert "\n")))
    (point)))

;;; Org note entry points

(global-set-key (kbd "C-c n d") #'sk/org-open-daily-note)
(global-set-key (kbd "C-c n w") #'sk/org-open-weekly-note)
(global-set-key (kbd "C-c j") #'org-capture)

;;; Org visual setup

(defun efs/org-font-setup ()
  ;; Replace list hyphen with dot
  (font-lock-add-keywords 'org-mode
                          '(("^ *\\([-]\\) "
                             (0 (prog1 () (compose-region (match-beginning 1) (match-end 1) "•"))))))

  ;; Set faces for heading levels
  (dolist (face '((org-level-1 . 1.2)
                  (org-level-2 . 1.1)
                  (org-level-3 . 1.05)
                  (org-level-4 . 1.0)
                  (org-level-5 . 1.1)
                  (org-level-6 . 1.1)
                  (org-level-7 . 1.1)
                  (org-level-8 . 1.1)))
    (set-face-attribute (car face) nil :font "Cantarell" :weight 'regular :height (cdr face)))

  ;; Ensure that anything that should be fixed-pitch in Org files appears that way
  (set-face-attribute 'org-block nil :foreground nil :inherit 'fixed-pitch)
  (set-face-attribute 'org-code nil   :inherit '(shadow fixed-pitch))
  (set-face-attribute 'org-table nil   :inherit '(shadow fixed-pitch))
  (set-face-attribute 'org-verbatim nil :inherit '(shadow fixed-pitch))
  (set-face-attribute 'org-special-keyword nil :inherit '(font-lock-comment-face fixed-pitch))
  (set-face-attribute 'org-meta-line nil :inherit '(font-lock-comment-face fixed-pitch))
  (set-face-attribute 'org-checkbox nil :inherit 'fixed-pitch))

;;; Org core behavior

(use-package org
  :hook (org-mode . efs/org-mode-setup)
  :config
  (setq org-ellipsis " ▾")

    (setq org-agenda-start-with-log-mode t)
  (setq org-log-done 'time)
  (setq org-log-into-drawer t)

  (setq org-agenda-files
	'("~/Documents/OrgFiles/Tasks.org"
	  "~/Documents/OrgFiles/Habits.org"
	  "~/Documents/OrgFiles/Birthdays.org"))

  (require 'org-habit)
  (add-to-list 'org-modules 'org-habit)
  (setq org-habit-graph-column 60)

  (setq org-todo-keywords
    '((sequence "TODO(t)" "NEXT(n)" "|" "DONE(d!)")
      (sequence "BACKLOG(b)" "PLAN(p)" "READY(r)" "ACTIVE(a)" "REVIEW(v)" "WAIT(w@/!)" "HOLD(h)" "|" "COMPLETED(c)" "CANC(k@)")))

  (setq org-refile-targets
    '(("Archive.org" :maxlevel . 1)
      ("Tasks.org" :maxlevel . 1)))

  ;; Save Org buffers after refiling!
  (advice-add 'org-refile :after 'org-save-all-org-buffers)

  (setq org-tag-alist
    '((:startgroup)
       ; Put mutually exclusive tags here
       (:endgroup)
       ("@errand" . ?E)
       ("@home" . ?H)
       ("@work" . ?W)
       ("agenda" . ?a)
       ("planning" . ?p)
       ("publish" . ?P)
       ("batch" . ?b)
       ("note" . ?n)
       ("idea" . ?i)))

  ;; Configure custom agenda views
  (setq org-agenda-custom-commands
   '(("d" "Dashboard"
     ((agenda "" ((org-deadline-warning-days 7)))
      (todo "NEXT"
        ((org-agenda-overriding-header "Next Tasks")))
      (tags-todo "agenda/ACTIVE" ((org-agenda-overriding-header "Active Projects")))))

    ("n" "Next Tasks"
     ((todo "NEXT"
        ((org-agenda-overriding-header "Next Tasks")))))

    ("W" "Work Tasks" tags-todo "+work-email")

    ;; Low-effort next actions
    ("e" tags-todo "+TODO=\"NEXT\"+Effort<15&+Effort>0"
     ((org-agenda-overriding-header "Low Effort Tasks")
      (org-agenda-max-todos 20)
      (org-agenda-files org-agenda-files)))

    ("w" "Workflow Status"
     ((todo "WAIT"
            ((org-agenda-overriding-header "Waiting on External")
             (org-agenda-files org-agenda-files)))
      (todo "REVIEW"
            ((org-agenda-overriding-header "In Review")
             (org-agenda-files org-agenda-files)))
      (todo "PLAN"
            ((org-agenda-overriding-header "In Planning")
             (org-agenda-todo-list-sublevels nil)
             (org-agenda-files org-agenda-files)))
      (todo "BACKLOG"
            ((org-agenda-overriding-header "Project Backlog")
             (org-agenda-todo-list-sublevels nil)
             (org-agenda-files org-agenda-files)))
      (todo "READY"
            ((org-agenda-overriding-header "Ready for Work")
             (org-agenda-files org-agenda-files)))
      (todo "ACTIVE"
            ((org-agenda-overriding-header "Active Projects")
             (org-agenda-files org-agenda-files)))
      (todo "COMPLETED"
            ((org-agenda-overriding-header "Completed Projects")
             (org-agenda-files org-agenda-files)))
      (todo "CANC"
            ((org-agenda-overriding-header "Cancelled Projects")
             (org-agenda-files org-agenda-files)))))))

  (setq org-capture-templates
    `(("t" "Tasks / Projects")
      ("tt" "Task" entry (file+olp "~/Documents/OrgFiles/Tasks.org" "Inbox")
           "* TODO %?\n  %U\n  %a\n  %i" :empty-lines 1)

      ("j" "Journal Entries")
      ("jd" "Daily note" entry
           (function sk/org-daily-capture-target)
           "* %<%I:%M %p> %?\n"
           :empty-lines 1)
      ("jj" "Journal" entry
           (file+olp+datetree "~/Documents/OrgFiles/Journal.org")
           "\n* %<%I:%M %p> - Journal :journal:\n\n%?\n\n"
           ;; ,(sk/read-file-as-string "~/Notes/Templates/Daily.org")
           :clock-in :clock-resume
           :empty-lines 1)
      ("jm" "Meeting" entry
           (file+olp+datetree "~/Documents/OrgFiles/Journal.org")
           "* %<%I:%M %p> - %a :meetings:\n\n%?\n\n"
           :clock-in :clock-resume
           :empty-lines 1)

      ("w" "Workflows")
      ("we" "Checking Email" entry (file+olp+datetree "~/Documents/OrgFiles/Journal.org")
           "* Checking Email :email:\n\n%?" :clock-in :clock-resume :empty-lines 1)

      ("m" "Metrics Capture")
      ("mw" "Weight" table-line (file+headline "~/Documents/OrgFiles/Metrics.org" "Weight")
       "| %U | %^{Weight} | %^{Notes} |" :kill-buffer t)))

  (efs/org-font-setup))

;;; Org bullets

(use-package org-bullets
  :after org
  :hook (org-mode . org-bullets-mode)
  :custom
  (org-bullets-bullet-list '("◉" "○" "●" "○" "●" "○" "●")))

;;; Org reading layout

(defun efs/org-mode-visual-fill ()
  (when (require 'visual-fill-column nil t)
    (setq visual-fill-column-width 100
          visual-fill-column-center-text t)
    (visual-fill-column-mode 1)))

(use-package visual-fill-column
  :hook (org-mode . efs/org-mode-visual-fill))
