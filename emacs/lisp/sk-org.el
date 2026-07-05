;;; sk-org.el --- Org basics -*- lexical-binding: t; -*-

(defvar sk/org-localleader-map (make-sparse-keymap)
  "Org mode commands under the Doom-style local leader.")

(defvar sk/org-attach-map (make-sparse-keymap)
  "Org attachment commands under `sk/org-localleader-map'.")

(defvar sk/org-clock-map (make-sparse-keymap)
  "Org clock commands under `sk/org-localleader-map'.")

(defvar sk/org-date-map (make-sparse-keymap)
  "Org date and deadline commands under `sk/org-localleader-map'.")

(defvar sk/org-goto-map (make-sparse-keymap)
  "Org goto commands under `sk/org-localleader-map'.")

(defvar sk/org-link-map (make-sparse-keymap)
  "Org link commands under `sk/org-localleader-map'.")

(defvar sk/org-priority-map (make-sparse-keymap)
  "Org priority commands under `sk/org-localleader-map'.")

(defvar sk/org-refile-map (make-sparse-keymap)
  "Org refile commands under `sk/org-localleader-map'.")

(defvar sk/org-subtree-map (make-sparse-keymap)
  "Org subtree commands under `sk/org-localleader-map'.")

(defvar sk/org-table-map (make-sparse-keymap)
  "Org table commands under `sk/org-localleader-map'.")

(defvar sk/org-table-delete-map (make-sparse-keymap)
  "Org table delete commands under `sk/org-table-map'.")

(defvar sk/org-table-insert-map (make-sparse-keymap)
  "Org table insert commands under `sk/org-table-map'.")

(defvar sk/org-table-toggle-map (make-sparse-keymap)
  "Org table toggle commands under `sk/org-table-map'.")

(defvar sk/org-babel-map (make-sparse-keymap)
  "Org source-block commands under `sk/org-localleader-map'.")

(defvar sk/org-agenda-localleader-map (make-sparse-keymap)
  "Org agenda commands under the Doom-style local leader.")

(defvar sk/org-agenda-clock-map (make-sparse-keymap)
  "Org agenda clock commands under `sk/org-agenda-localleader-map'.")

(defvar sk/org-agenda-date-map (make-sparse-keymap)
  "Org agenda date commands under `sk/org-agenda-localleader-map'.")

(defvar sk/org-agenda-priority-map (make-sparse-keymap)
  "Org agenda priority commands under `sk/org-agenda-localleader-map'.")

(defvar sk/org-source-block-languages
  '("emacs-lisp" "sh" "bash" "nix" "lua" "qml" "rust" "c" "python" "haskell" "json" "yaml" "glsl")
  "Languages offered when inserting Org source blocks.")

(defun sk/org-mode-setup ()
  "Enable the default editing setup for Org buffers."
  (org-indent-mode)
  (variable-pitch-mode 1)
  (visual-line-mode 1))

(defun sk/org-source-block-language-at-point ()
  "Return the Org source-block language at point, when point is in one."
  (when (derived-mode-p 'org-mode)
    (let ((context (org-element-context)))
      (when (eq (org-element-type context) 'src-block)
        (org-element-property :language context)))))

(defun sk/org-read-source-block-language ()
  "Read an Org source-block language with a useful default."
  (let ((default (or (sk/org-source-block-language-at-point) "emacs-lisp")))
    (completing-read
     (format "Source language (%s): " default)
     sk/org-source-block-languages nil nil nil nil default)))

(defun sk/org-insert-source-block (language)
  "Insert an Org source block for LANGUAGE, wrapping the active region if any."
  (interactive (list (sk/org-read-source-block-language)))
  (let ((has-region (use-region-p)))
    (if has-region
        (let* ((beg (region-beginning))
               (end (region-end))
               (body (buffer-substring-no-properties beg end)))
          (delete-region beg end)
          (insert "#+begin_src " language "\n" body)
          (when (and (> (length body) 0)
                     (not (eq (aref body (1- (length body))) ?\n)))
            (insert "\n"))
          (insert "#+end_src\n")
          (deactivate-mark))
      (insert "#+begin_src " language "\n\n#+end_src")
      (forward-line -1))))

(defun sk/org-font-setup ()
  "Set readable Org faces while keeping code-like content fixed-pitch."
  (font-lock-add-keywords
   'org-mode
   '(("^ *\\([-]\\) "
      (0 (prog1 () (compose-region (match-beginning 1) (match-end 1) "•"))))))
  (dolist (face '((org-level-1 . 1.2)
                  (org-level-2 . 1.1)
                  (org-level-3 . 1.05)
                  (org-level-4 . 1.0)
                  (org-level-5 . 1.1)
                  (org-level-6 . 1.1)
                  (org-level-7 . 1.1)
                  (org-level-8 . 1.1)))
    (set-face-attribute (car face) nil :font "Cantarell" :weight 'regular :height (cdr face)))
  (set-face-attribute 'org-block nil :foreground nil :inherit 'fixed-pitch)
  (set-face-attribute 'org-code nil :inherit '(shadow fixed-pitch))
  (set-face-attribute 'org-table nil :inherit '(shadow fixed-pitch))
  (set-face-attribute 'org-verbatim nil :inherit '(shadow fixed-pitch))
  (set-face-attribute 'org-special-keyword nil :inherit '(font-lock-comment-face fixed-pitch))
  (set-face-attribute 'org-meta-line nil :inherit '(font-lock-comment-face fixed-pitch))
  (set-face-attribute 'org-checkbox nil :inherit 'fixed-pitch))

(defun sk/org-mode-visual-fill ()
  "Center Org text with a comfortable width."
  (when (require 'visual-fill-column nil t)
    (setq visual-fill-column-width 100
          visual-fill-column-center-text t)
    (visual-fill-column-mode 1)))

(define-key sk/org-localleader-map (kbd "#") #'org-update-statistics-cookies)
(define-key sk/org-localleader-map (kbd "'") #'org-edit-special)
(define-key sk/org-localleader-map (kbd "*") #'org-ctrl-c-star)
(define-key sk/org-localleader-map (kbd "-") #'org-ctrl-c-minus)
(define-key sk/org-localleader-map (kbd ",") #'org-switchb)
(define-key sk/org-localleader-map (kbd ".") #'org-goto)
(define-key sk/org-localleader-map (kbd "A") #'org-archive-subtree-default)
(define-key sk/org-localleader-map (kbd "e") #'org-export-dispatch)
(define-key sk/org-localleader-map (kbd "f") #'org-footnote-action)
(define-key sk/org-localleader-map (kbd "h") #'org-toggle-heading)
(define-key sk/org-localleader-map (kbd "i") #'org-toggle-item)
(define-key sk/org-localleader-map (kbd "I") #'org-id-get-create)
(define-key sk/org-localleader-map (kbd "k") #'org-babel-remove-result)
(define-key sk/org-localleader-map (kbd "n") #'org-store-link)
(define-key sk/org-localleader-map (kbd "o") #'org-set-property)
(define-key sk/org-localleader-map (kbd "q") #'org-set-tags-command)
(define-key sk/org-localleader-map (kbd "t") #'org-todo)
(define-key sk/org-localleader-map (kbd "T") #'org-todo-list)
(define-key sk/org-localleader-map (kbd "x") #'org-toggle-checkbox)
(define-key sk/org-localleader-map (kbd "a") sk/org-attach-map)
(define-key sk/org-localleader-map (kbd "B") sk/org-babel-map)
(define-key sk/org-localleader-map (kbd "b") sk/org-table-map)
(define-key sk/org-localleader-map (kbd "c") sk/org-clock-map)
(define-key sk/org-localleader-map (kbd "d") sk/org-date-map)
(define-key sk/org-localleader-map (kbd "g") sk/org-goto-map)
(define-key sk/org-localleader-map (kbd "l") sk/org-link-map)
(define-key sk/org-localleader-map (kbd "p") sk/org-priority-map)
(define-key sk/org-localleader-map (kbd "r") sk/org-refile-map)
(define-key sk/org-localleader-map (kbd "s") sk/org-subtree-map)

(define-key sk/org-attach-map (kbd "a") #'org-attach)
(define-key sk/org-attach-map (kbd "d") #'org-attach-delete-one)
(define-key sk/org-attach-map (kbd "D") #'org-attach-delete-all)
(define-key sk/org-attach-map (kbd "n") #'org-attach-new)
(define-key sk/org-attach-map (kbd "o") #'org-attach-open)
(define-key sk/org-attach-map (kbd "r") #'org-attach-reveal)
(define-key sk/org-attach-map (kbd "s") #'org-attach-set-directory)
(define-key sk/org-attach-map (kbd "S") #'org-attach-sync)
(define-key sk/org-attach-map (kbd "u") #'org-attach-url)

(define-key sk/org-clock-map (kbd "c") #'org-clock-cancel)
(define-key sk/org-clock-map (kbd "e") #'org-clock-modify-effort-estimate)
(define-key sk/org-clock-map (kbd "E") #'org-set-effort)
(define-key sk/org-clock-map (kbd "g") #'org-clock-goto)
(define-key sk/org-clock-map (kbd "i") #'org-clock-in)
(define-key sk/org-clock-map (kbd "I") #'org-clock-in-last)
(define-key sk/org-clock-map (kbd "o") #'org-clock-out)
(define-key sk/org-clock-map (kbd "r") #'org-resolve-clocks)
(define-key sk/org-clock-map (kbd "R") #'org-clock-report)
(define-key sk/org-clock-map (kbd "t") #'org-evaluate-time-range)

(define-key sk/org-date-map (kbd "d") #'org-deadline)
(define-key sk/org-date-map (kbd "s") #'org-schedule)
(define-key sk/org-date-map (kbd "t") #'org-time-stamp)
(define-key sk/org-date-map (kbd "T") #'org-time-stamp-inactive)

(define-key sk/org-goto-map (kbd "g") #'org-goto)
(define-key sk/org-goto-map (kbd "c") #'org-clock-goto)
(define-key sk/org-goto-map (kbd "i") #'org-id-goto)
(define-key sk/org-goto-map (kbd "r") #'org-refile-goto-last-stored)
(define-key sk/org-goto-map (kbd "x") #'org-capture-goto-last-stored)

(define-key sk/org-link-map (kbd "i") #'org-id-store-link)
(define-key sk/org-link-map (kbd "l") #'org-insert-link)
(define-key sk/org-link-map (kbd "s") #'org-store-link)
(define-key sk/org-link-map (kbd "t") #'org-toggle-link-display)

(define-key sk/org-priority-map (kbd "d") #'org-priority-down)
(define-key sk/org-priority-map (kbd "p") #'org-priority)
(define-key sk/org-priority-map (kbd "u") #'org-priority-up)

(define-key sk/org-refile-map (kbd "r") #'org-refile)

(define-key sk/org-subtree-map (kbd "a") #'org-toggle-archive-tag)
(define-key sk/org-subtree-map (kbd "b") #'org-tree-to-indirect-buffer)
(define-key sk/org-subtree-map (kbd "c") #'org-clone-subtree-with-time-shift)
(define-key sk/org-subtree-map (kbd "d") #'org-cut-subtree)
(define-key sk/org-subtree-map (kbd "h") #'org-promote-subtree)
(define-key sk/org-subtree-map (kbd "j") #'org-move-subtree-down)
(define-key sk/org-subtree-map (kbd "k") #'org-move-subtree-up)
(define-key sk/org-subtree-map (kbd "l") #'org-demote-subtree)
(define-key sk/org-subtree-map (kbd "n") #'org-narrow-to-subtree)
(define-key sk/org-subtree-map (kbd "r") #'org-refile)
(define-key sk/org-subtree-map (kbd "s") #'org-sparse-tree)
(define-key sk/org-subtree-map (kbd "A") #'org-archive-subtree-default)
(define-key sk/org-subtree-map (kbd "N") #'widen)
(define-key sk/org-subtree-map (kbd "S") #'org-sort)

(define-key sk/org-table-map (kbd "-") #'org-table-insert-hline)
(define-key sk/org-table-map (kbd "a") #'org-table-align)
(define-key sk/org-table-map (kbd "b") #'org-table-blank-field)
(define-key sk/org-table-map (kbd "c") #'org-table-create-or-convert-from-region)
(define-key sk/org-table-map (kbd "e") #'org-table-edit-field)
(define-key sk/org-table-map (kbd "f") #'org-table-edit-formulas)
(define-key sk/org-table-map (kbd "h") #'org-table-field-info)
(define-key sk/org-table-map (kbd "s") #'org-table-sort-lines)
(define-key sk/org-table-map (kbd "r") #'org-table-recalculate)
(define-key sk/org-table-map (kbd "R") #'org-table-recalculate-buffer-tables)
(define-key sk/org-table-map (kbd "d") sk/org-table-delete-map)
(define-key sk/org-table-map (kbd "i") sk/org-table-insert-map)
(define-key sk/org-table-map (kbd "t") sk/org-table-toggle-map)

(define-key sk/org-table-delete-map (kbd "c") #'org-table-delete-column)
(define-key sk/org-table-delete-map (kbd "r") #'org-table-kill-row)

(define-key sk/org-table-insert-map (kbd "c") #'org-table-insert-column)
(define-key sk/org-table-insert-map (kbd "h") #'org-table-insert-hline)
(define-key sk/org-table-insert-map (kbd "r") #'org-table-insert-row)
(define-key sk/org-table-insert-map (kbd "H") #'org-table-hline-and-move)

(define-key sk/org-table-toggle-map (kbd "f") #'org-table-toggle-formula-debugger)
(define-key sk/org-table-toggle-map (kbd "o") #'org-table-toggle-coordinate-overlays)

(define-key sk/org-babel-map (kbd "'") #'org-edit-special)
(define-key sk/org-babel-map (kbd "e") #'org-babel-execute-src-block)
(define-key sk/org-babel-map (kbd "g") #'org-babel-goto-named-src-block)
(define-key sk/org-babel-map (kbd "i") #'sk/org-insert-source-block)
(define-key sk/org-babel-map (kbd "n") #'org-babel-next-src-block)
(define-key sk/org-babel-map (kbd "p") #'org-babel-previous-src-block)
(define-key sk/org-babel-map (kbd "r") #'org-babel-remove-result)
(define-key sk/org-babel-map (kbd "t") #'org-babel-tangle)

(define-key sk/org-agenda-localleader-map (kbd "t") #'org-agenda-todo)
(define-key sk/org-agenda-localleader-map (kbd "q") #'org-agenda-set-tags)
(define-key sk/org-agenda-localleader-map (kbd "r") #'org-agenda-refile)
(define-key sk/org-agenda-localleader-map (kbd "c") sk/org-agenda-clock-map)
(define-key sk/org-agenda-localleader-map (kbd "d") sk/org-agenda-date-map)
(define-key sk/org-agenda-localleader-map (kbd "p") sk/org-agenda-priority-map)

(define-key sk/org-agenda-clock-map (kbd "c") #'org-agenda-clock-cancel)
(define-key sk/org-agenda-clock-map (kbd "g") #'org-agenda-clock-goto)
(define-key sk/org-agenda-clock-map (kbd "i") #'org-agenda-clock-in)
(define-key sk/org-agenda-clock-map (kbd "o") #'org-agenda-clock-out)
(define-key sk/org-agenda-clock-map (kbd "r") #'org-agenda-clockreport-mode)
(define-key sk/org-agenda-clock-map (kbd "s") #'org-agenda-show-clocking-issues)

(define-key sk/org-agenda-date-map (kbd "d") #'org-agenda-deadline)
(define-key sk/org-agenda-date-map (kbd "s") #'org-agenda-schedule)

(define-key sk/org-agenda-priority-map (kbd "d") #'org-agenda-priority-down)
(define-key sk/org-agenda-priority-map (kbd "p") #'org-agenda-priority)
(define-key sk/org-agenda-priority-map (kbd "u") #'org-agenda-priority-up)

(with-eval-after-load 'which-key
  (which-key-add-key-based-replacements
    "SPC m" "org"
    "SPC m '" "edit source block"
    "SPC m A" "archive subtree"
    "SPC m B" "source blocks"
    "SPC m B e" "execute source block"
    "SPC m B g" "goto named source block"
    "SPC m B i" "insert source block"
    "SPC m B n" "next source block"
    "SPC m B p" "previous source block"
    "SPC m B r" "remove result"
    "SPC m B t" "tangle file"
    "SPC m a" "attachments"
    "SPC m b" "tables"
    "SPC m c" "clock"
    "SPC m d" "dates"
    "SPC m e" "export"
    "SPC m g" "goto"
    "SPC m l" "links"
    "SPC m p" "priority"
    "SPC m q" "tags"
    "SPC m r" "refile"
    "SPC m s" "subtree"
    "SPC m t" "todo"
    "SPC m x" "checkbox"))

(use-package org
  :ensure nil
  :mode ("\\.org\\'" . org-mode)
  :hook ((org-mode . sk/org-mode-setup)
         (org-mode . sk/org-mode-visual-fill))
  :config
  (setq org-startup-indented t
        org-hide-emphasis-markers t
        org-log-done 'time
        org-log-into-drawer t
        org-image-actual-width nil
        org-ellipsis " ▾"
        org-src-fontify-natively t
        org-src-tab-acts-natively t
        org-src-window-setup 'current-window
        org-edit-src-content-indentation 0
        org-src-preserve-indentation nil
        org-confirm-babel-evaluate t)
  (org-babel-do-load-languages
   'org-babel-load-languages
   '((emacs-lisp . t)
     (shell . t)
     (python . t)
     (lua . t)))
  (require 'org-habit)
  (add-to-list 'org-modules 'org-habit)
  (setq org-habit-graph-column 60)
  (require 'org-tempo)
  (dolist (template '(("sh" . "src sh")
                      ("bash" . "src bash")
                      ("el" . "src emacs-lisp")
                      ("nix" . "src nix")
                      ("lua" . "src lua")
                      ("qml" . "src qml")
                      ("rs" . "src rust")
                      ("c" . "src c")
                      ("py" . "src python")
                      ("hs" . "src haskell")
                      ("json" . "src json")
                      ("yaml" . "src yaml")
                      ("glsl" . "src glsl")))
    (setq org-structure-template-alist
          (assoc-delete-all (car template) org-structure-template-alist))
    (add-to-list 'org-structure-template-alist template))
  (sk/org-font-setup)
  (add-hook 'org-mode-hook
            (lambda ()
              (when (fboundp 'evil-local-set-key)
                (evil-local-set-key 'normal (kbd "[[") #'org-previous-visible-heading)
                (evil-local-set-key 'normal (kbd "]]") #'org-next-visible-heading)
                (evil-local-set-key 'normal (kbd "[h") #'org-previous-visible-heading)
                (evil-local-set-key 'normal (kbd "]h") #'org-next-visible-heading)
                (evil-local-set-key 'normal (kbd "[s") #'org-backward-heading-same-level)
                (evil-local-set-key 'normal (kbd "]s") #'org-forward-heading-same-level)
                (evil-local-set-key 'normal (kbd "gh") #'outline-up-heading)
                (evil-local-set-key 'normal (kbd "gj") #'org-next-visible-heading)
                (evil-local-set-key 'normal (kbd "gk") #'org-previous-visible-heading)
                (evil-local-set-key 'normal (kbd "gl") #'org-goto)
                (evil-local-set-key 'normal (kbd "TAB") #'org-cycle)
                (evil-local-set-key 'normal (kbd "<tab>") #'org-cycle)
                (evil-local-set-key 'normal (kbd "<backtab>") #'org-shifttab)
                (evil-local-set-key 'normal (kbd "S-TAB") #'org-shifttab)
                (evil-local-set-key 'normal (kbd "za") #'org-cycle)
                (evil-local-set-key 'normal (kbd "zA") #'org-shifttab)
                (evil-local-set-key 'normal (kbd ">") #'org-demote-subtree)
                (evil-local-set-key 'normal (kbd "<") #'org-promote-subtree)
                (evil-local-set-key 'normal (kbd "M-j") #'org-metadown)
                (evil-local-set-key 'normal (kbd "M-k") #'org-metaup))))
  (with-eval-after-load 'evil
    (evil-define-key '(normal motion) org-mode-map (kbd "SPC m") sk/org-localleader-map))
  (with-eval-after-load 'org-agenda
    (define-key org-agenda-mode-map (kbd "C-SPC") #'org-agenda-show-and-scroll-up)
    (with-eval-after-load 'evil
      (evil-define-key '(normal motion) org-agenda-mode-map (kbd "SPC m") sk/org-agenda-localleader-map))))

(use-package org-bullets
  :after org
  :hook (org-mode . org-bullets-mode)
  :custom
  (org-bullets-bullet-list '("◉" "○" "●" "○" "●" "○" "●")))

(provide 'sk-org)

;;; sk-org.el ends here
