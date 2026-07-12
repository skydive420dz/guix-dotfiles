;;; sk-window-policy.el --- Shared window and panel policy -*- lexical-binding: t; -*-

(require 'seq)
(require 'subr-x)
(require 'xref)

(defconst sk/window-reviewed-emacs-major-version 30
  "Emacs major release reviewed for the Xref result adapter.")

(defvar sk/window-xref-compatible-p
  (and (= emacs-major-version sk/window-reviewed-emacs-major-version)
       (fboundp 'xref-pop-to-location)
       (boundp 'xref-buffer-name))
  "Non-nil when the reviewed Xref result adapter can be installed.")

(defconst sk/window-xref-buffer-name
  (if (boundp 'xref-buffer-name) xref-buffer-name "*xref*")
  "Xref result buffer name used by the reviewed display policy.")

(unless sk/window-xref-compatible-p
  (display-warning
   'sk-window-policy
   (format "Xref RET adapter disabled: Emacs %s is outside reviewed major %s"
           emacs-version sk/window-reviewed-emacs-major-version)
   :warning))

(defvar sk/window-master-width-ratio 0.62
  "Width ratio used for the left master window.")

(defun sk/window-clear-side-state (window)
  "Clear stale side-window metadata from WINDOW."
  (set-window-dedicated-p window nil)
  (dolist (parameter '(window-side window-slot no-delete-other-windows))
    (set-window-parameter window parameter nil)))

(defun sk/window-clear-stale-side-state ()
  "Clear stale side-window metadata from regular windows.
Real side windows are dedicated with the value `side' and are left alone."
  (interactive)
  (dolist (window (window-list nil 'no-minibuf))
    (when (and (window-parameter window 'window-side)
               (not (eq (window-dedicated-p window) 'side)))
      (sk/window-clear-side-state window))))

(defun sk/window-regular-p (window)
  "Return non-nil when WINDOW is available for master/stack layout."
  (not (window-parameter window 'window-side)))

(defun sk/window-side-window-p (&optional window)
  "Return non-nil when WINDOW is a helper side window."
  (window-parameter (or window (selected-window)) 'window-side))

(defun sk/window-list (&optional frame)
  "Return regular, non-side windows on FRAME."
  (let (windows)
    (dolist (window (window-list frame 'no-minibuf))
      (when (sk/window-regular-p window)
        (push window windows)))
    (nreverse windows)))

(defun sk/window-buffer-list (&optional frame)
  "Return buffers displayed in regular windows on FRAME."
  (delete-dups (mapcar #'window-buffer (sk/window-list frame))))

(defun sk/window-master ()
  "Return the current workspace master window.
The master window is the left-most regular window on the frame."
  (car (sort (copy-sequence (sk/window-list))
             (lambda (left right)
               (let ((left-edges (window-edges left))
                     (right-edges (window-edges right)))
                 (or (< (nth 0 left-edges) (nth 0 right-edges))
                     (and (= (nth 0 left-edges) (nth 0 right-edges))
                          (< (nth 1 left-edges) (nth 1 right-edges)))))))))

(defun sk/window-stack ()
  "Return non-master regular windows sorted from top to bottom."
  (let ((master (sk/window-master)))
    (sort (delq master (copy-sequence (sk/window-list)))
          (lambda (left right)
            (< (nth 1 (window-edges left))
               (nth 1 (window-edges right)))))))

(defun sk/window-master-width ()
  "Return the desired master width in columns."
  (max window-min-width
       (floor (* (frame-width) sk/window-master-width-ratio))))

(defun sk/window-splittable-stack-p (window)
  "Return non-nil when WINDOW has enough height to split into stack items."
  (>= (window-total-height window)
      (+ (* 2 window-min-height) 4)))

(defun sk/window-new-stack-window ()
  "Return a window where a new regular buffer should appear.
Create a master/stack layout when the workspace has only one regular window."
  (sk/window-clear-stale-side-state)
  (let* ((windows (sk/window-list))
         (master (sk/window-master))
         (stack (sk/window-stack)))
    (cond
     ((null windows)
      (user-error "No regular window available for stack"))
     ((null stack)
      (with-selected-window master
        (let ((window (split-window-right (sk/window-master-width))))
          (sk/window-clear-side-state window)
          window)))
     (t
      (let ((target (car (last stack))))
        (if (sk/window-splittable-stack-p target)
            (let ((window (split-window target nil 'below)))
              (sk/window-clear-side-state window)
              window)
          (progn
            (sk/window-clear-side-state target)
            target)))))))

(defun sk/window-display-in-stack (buffer)
  "Display BUFFER in the regular right-side stack."
  (let ((window (sk/window-new-stack-window)))
    (set-window-buffer window buffer)
    (select-window window)
    window))

(defun sk/window-main-window ()
  "Return the main editing window."
  (or (sk/window-master)
      (car (sk/window-list))
      (selected-window)))

(defun sk/window-display-in-main (buffer &optional select)
  "Display BUFFER in the main editing window.
Select the target window when SELECT is non-nil."
  (let ((window (sk/window-main-window)))
    (set-window-buffer window buffer)
    (when select
      (select-window window))
    window))

(defun sk/window-open-file-in-main (file)
  "Open FILE in the main editing window."
  (sk/window-display-in-main (find-file-noselect file) t))

(defun sk/window-call-command-from-main-when-side (command)
  "Call COMMAND from the main window when currently in a side window.
The current `default-directory' is preserved so helper panels still provide the
expected starting location for file prompts."
  (let ((directory default-directory))
    (if (sk/window-side-window-p)
        (progn
          (select-window (sk/window-main-window))
          (let ((default-directory directory))
            (call-interactively command)))
      (call-interactively command))))

(defun sk/window-counsel-find-file ()
  "Run `counsel-find-file' without opening targets inside helper windows."
  (interactive)
  (sk/window-call-command-from-main-when-side #'counsel-find-file))

(defun sk/window-counsel-fzf ()
  "Run `counsel-fzf' without opening targets inside helper windows."
  (interactive)
  (sk/window-call-command-from-main-when-side #'counsel-fzf))

(defun sk/window-counsel-projectile-find-file ()
  "Run `counsel-projectile-find-file' without opening targets in helpers."
  (interactive)
  (sk/window-call-command-from-main-when-side #'counsel-projectile-find-file))

(defun sk/window-promote-to-master ()
  "Swap the selected regular window with the current master window."
  (interactive)
  (sk/window-clear-stale-side-state)
  (let ((master (sk/window-master))
        (selected (selected-window)))
    (unless (eq selected master)
      (window-swap-states selected master)
      (select-window master))))

(defun sk/window-normalize-master-stack ()
  "Normalize visible regular windows into a left master and right stack."
  (interactive)
  (sk/window-clear-stale-side-state)
  (let* ((selected-buffer (current-buffer))
         (buffers (sk/window-buffer-list))
         (stack-buffers (delq selected-buffer (copy-sequence buffers))))
    (sk/window-display-master-stack selected-buffer stack-buffers)))

(defun sk/window-display-master-stack (master-buffer stack-buffers)
  "Display MASTER-BUFFER on the left and STACK-BUFFERS on the right."
  (sk/window-clear-stale-side-state)
  (let ((stack-buffers (delq master-buffer (delete-dups stack-buffers))))
    (delete-other-windows)
    (switch-to-buffer master-buffer)
    (when stack-buffers
      (let ((stack-window (split-window-right (sk/window-master-width))))
        (sk/window-clear-side-state stack-window)
        (set-window-buffer stack-window (car stack-buffers))
        (select-window stack-window)
        (dolist (buffer (cdr stack-buffers))
          (let ((next-window (split-window nil nil 'below)))
            (sk/window-clear-side-state next-window)
            (set-window-buffer next-window buffer)
            (select-window next-window)))))
    (select-window (sk/window-master))))

(defun sk/window-split-right-and-focus ()
  "Split the selected regular window to the right and focus the new window."
  (interactive)
  (let ((window (split-window-right)))
    (sk/window-clear-side-state window)
    (select-window window)))

(defun sk/window-split-below-and-focus ()
  "Split the selected regular window below and focus the new window."
  (interactive)
  (let ((window (split-window-below)))
    (sk/window-clear-side-state window)
    (select-window window)))

(defun sk/window-next ()
  "Move to the next window."
  (interactive)
  (other-window 1))

(defun sk/window-previous ()
  "Move to the previous window."
  (interactive)
  (other-window -1))

(defun sk/window-overlap-size (start-a end-a start-b end-b)
  "Return the overlap size between ranges START-A END-A and START-B END-B."
  (max 0 (- (min end-a end-b) (max start-a start-b))))

(defun sk/window-rank-less-p (left right)
  "Return non-nil when rank list LEFT is better than rank list RIGHT."
  (catch 'done
    (while (and left right)
      (cond
       ((< (car left) (car right))
        (throw 'done t))
       ((> (car left) (car right))
        (throw 'done nil)))
      (setq left (cdr left)
            right (cdr right)))
    nil))

(defun sk/window-direction-rank (direction selected candidate)
  "Return CANDIDATE rank moving from SELECTED in DIRECTION, or nil."
  (let* ((selected-edges (window-edges selected))
         (candidate-edges (window-edges candidate))
         (selected-left (nth 0 selected-edges))
         (selected-top (nth 1 selected-edges))
         (selected-right (nth 2 selected-edges))
         (selected-bottom (nth 3 selected-edges))
         (candidate-left (nth 0 candidate-edges))
         (candidate-top (nth 1 candidate-edges))
         (candidate-right (nth 2 candidate-edges))
         (candidate-bottom (nth 3 candidate-edges))
         (selected-x (/ (+ selected-left selected-right) 2.0))
         (selected-y (/ (+ selected-top selected-bottom) 2.0))
         (candidate-x (/ (+ candidate-left candidate-right) 2.0))
         (candidate-y (/ (+ candidate-top candidate-bottom) 2.0)))
    (pcase direction
      ('left
       (when (<= candidate-right selected-left)
         (list (- selected-left candidate-right)
               (- (sk/window-overlap-size selected-top selected-bottom
                                          candidate-top candidate-bottom))
               (abs (- selected-y candidate-y))
               (abs (- selected-x candidate-x)))))
      ('right
       (when (>= candidate-left selected-right)
         (list (- candidate-left selected-right)
               (- (sk/window-overlap-size selected-top selected-bottom
                                          candidate-top candidate-bottom))
               (abs (- selected-y candidate-y))
               (abs (- selected-x candidate-x)))))
      ('up
       (when (<= candidate-bottom selected-top)
         (list (- selected-top candidate-bottom)
               (- (sk/window-overlap-size selected-left selected-right
                                          candidate-left candidate-right))
               (abs (- selected-x candidate-x))
               (abs (- selected-y candidate-y)))))
      ('down
       (when (>= candidate-top selected-bottom)
         (list (- candidate-top selected-bottom)
               (- (sk/window-overlap-size selected-left selected-right
                                          candidate-left candidate-right))
               (abs (- selected-x candidate-x))
               (abs (- selected-y candidate-y))))))))

(defun sk/window-select-direction (direction)
  "Select the nearest visible window in DIRECTION.
Unlike raw `windmove', this includes side/helper windows such as Treemacs,
Dired, Help, Eshell, and diagnostic panels."
  (interactive)
  (let* ((selected (selected-window))
         (candidates
          (delq nil
                (mapcar (lambda (window)
                          (unless (eq window selected)
                            (when-let ((rank (sk/window-direction-rank
                                               direction selected window)))
                              (cons rank window))))
                        (window-list nil 'no-minibuf)))))
    (if candidates
        (select-window
         (cdr (car (sort candidates
                         (lambda (left right)
                           (sk/window-rank-less-p (car left) (car right)))))))
      (user-error "No window to the %s" direction))))

(defun sk/window-left ()
  "Select the nearest visible window to the left."
  (interactive)
  (sk/window-select-direction 'left))

(defun sk/window-down ()
  "Select the nearest visible window below."
  (interactive)
  (sk/window-select-direction 'down))

(defun sk/window-up ()
  "Select the nearest visible window above."
  (interactive)
  (sk/window-select-direction 'up))

(defun sk/window-right ()
  "Select the nearest visible window to the right."
  (interactive)
  (sk/window-select-direction 'right))

(defun sk/window-resize-left ()
  "Shrink the selected window horizontally."
  (interactive)
  (shrink-window-horizontally 5))

(defun sk/window-resize-right ()
  "Enlarge the selected window horizontally."
  (interactive)
  (enlarge-window-horizontally 5))

(defun sk/window-resize-down ()
  "Shrink the selected window vertically."
  (interactive)
  (shrink-window 3))

(defun sk/window-resize-up ()
  "Enlarge the selected window vertically."
  (interactive)
  (enlarge-window 3))

(defun sk/window-display-right (buffer &optional width slot)
  "Display BUFFER in a right utility side window."
  (display-buffer-in-side-window
   buffer
   `((side . right)
     (slot . ,(or slot 0))
     (window-width . ,(or width 0.42))
     (window-parameters . ((no-delete-other-windows . t))))))

(defun sk/window-display-bottom (buffer &optional height slot)
  "Display BUFFER in a bottom transient side window."
  (display-buffer-in-side-window
   buffer
   `((side . bottom)
     (slot . ,(or slot 0))
     (window-height . ,(or height 0.28))
     (window-parameters . ((no-delete-other-windows . t))))))

(defun sk/window-open-dired (&optional prompt)
  "Open Dired for `default-directory' in the utility side window.
With PROMPT, ask for a directory."
  (interactive "P")
  (let* ((directory (if prompt
                        (read-directory-name "Dired: " nil nil t)
                      default-directory))
         (buffer (dired-noselect directory))
         (window (sk/window-display-right buffer)))
    (select-window window)))

(defun sk/window-open-ibuffer ()
  "Open Ibuffer in the utility side window."
  (interactive)
  (ibuffer t "*Ibuffer*"))

(defun sk/window-open-eshell ()
  "Open Eshell in the utility side window."
  (interactive)
  (let ((buffer (save-window-excursion
                  (eshell)
                  (current-buffer))))
    (select-window (sk/window-display-right buffer))))

(defun sk/window-open-term ()
  "Open Term in the utility side window."
  (interactive)
  (let ((program (or explicit-shell-file-name
                     (getenv "SHELL")
                     shell-file-name)))
    (let ((buffer (save-window-excursion
                    (term program)
                    (current-buffer))))
      (select-window (sk/window-display-right buffer)))))

(defun sk/window-open-vterm ()
  "Open Vterm in the utility side window."
  (interactive)
  (unless (require 'vterm nil t)
    (user-error "vterm is not available in this Guix profile yet"))
  (let ((buffer (save-window-excursion
                  (vterm)
                  (current-buffer))))
    (select-window (sk/window-display-right buffer))))

(defun sk/window-open-treemacs ()
  "Open or select Treemacs in the left persistent panel."
  (interactive)
  (unless (require 'treemacs nil t)
    (user-error "treemacs is not available"))
  (setq treemacs-position 'left
        treemacs-width 35
        treemacs-is-never-other-window t
        treemacs-width-is-initially-locked t)
  (if-let ((window (and (fboundp 'treemacs-get-local-window)
                        (treemacs-get-local-window))))
      (select-window window)
    (treemacs)))

(defun sk/window-display-magit-buffer (buffer)
  "Display Magit BUFFER in the utility side window."
  (sk/window-display-right buffer 0.48))

(defun sk/window-dired-open ()
  "Open Dired file targets in the main window.
Directories continue replacing the Dired panel buffer."
  (interactive)
  (require 'dired)
  (let ((file (dired-get-file-for-visit)))
    (if (file-directory-p file)
        (set-window-buffer (selected-window) (dired-noselect file))
      (sk/window-open-file-in-main file))))

(defun sk/window-ibuffer-visit-buffer ()
  "Visit the Ibuffer buffer at point in the main window."
  (interactive)
  (require 'ibuffer)
  (sk/window-display-in-main (ibuffer-current-buffer t) t))

(defun sk/window-xref-goto-xref ()
  "Visit the Xref item at point in the main window."
  (interactive)
  (require 'xref)
  (unless sk/window-xref-compatible-p
    (user-error "Xref result navigation is not reviewed for Emacs %s"
                emacs-version))
  (let ((item (get-text-property
               (if (eolp) (max (point-min) (1- (point))) (point))
               'xref-item)))
    (unless item
      (user-error "No xref at point"))
    (select-window (sk/window-main-window))
    (xref-pop-to-location item)))

(defun sk/window-flycheck-error-list-goto-error (&optional pos)
  "Visit the Flycheck error at POS in the main window."
  (interactive)
  (require 'flycheck)
  (let ((error (tabulated-list-get-id pos)))
    (unless error
      (user-error "No Flycheck error at point"))
    (select-window (sk/window-main-window))
    (flycheck-jump-to-error error)
    (run-hooks 'flycheck-error-list-after-jump-hook)))

(defun sk/window-treemacs-RET-action ()
  "Open Treemacs file nodes in the main window.
Directories and non-file nodes keep Treemacs' default RET behavior."
  (interactive)
  (require 'treemacs)
  (let* ((button (treemacs-current-button))
         (path (and button (treemacs-button-get button :path))))
    (if (and (stringp path) (file-regular-p path))
        (sk/window-open-file-in-main path)
      (treemacs-RET-action))))

(with-eval-after-load 'dired
  (define-key dired-mode-map (kbd "RET") #'sk/window-dired-open))

(with-eval-after-load 'ibuffer
  (define-key ibuffer-mode-map (kbd "RET") #'sk/window-ibuffer-visit-buffer))

(defvar sk/window-xref-navigation-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'sk/window-xref-goto-xref)
    (define-key map [return] #'sk/window-xref-goto-xref)
    map)
  "Local navigation bindings for the public Xref result buffer.")

(define-minor-mode sk/window-xref-navigation-mode
  "Keep Xref result navigation aligned with the main-window policy."
  :init-value nil
  :lighter nil
  :keymap sk/window-xref-navigation-mode-map)

(defun sk/window-configure-xref-buffer ()
  "Enable GuixPC navigation bindings in the public Xref result buffer."
  (when (and sk/window-xref-compatible-p
             (equal (buffer-name) sk/window-xref-buffer-name))
    (sk/window-xref-navigation-mode 1)
    (when (fboundp 'evil-local-set-key)
      (evil-local-set-key 'normal (kbd "RET") #'sk/window-xref-goto-xref)
      (evil-local-set-key 'normal [return] #'sk/window-xref-goto-xref)
      (evil-local-set-key 'motion (kbd "RET") #'sk/window-xref-goto-xref)
      (evil-local-set-key 'motion [return] #'sk/window-xref-goto-xref))))

(add-hook 'xref-after-update-hook #'sk/window-configure-xref-buffer)

(with-eval-after-load 'flycheck
  (define-key flycheck-error-list-mode-map (kbd "RET") #'sk/window-flycheck-error-list-goto-error))

(with-eval-after-load 'evil
  ;; Evil/Evil Collection maps can shadow helper-local RET bindings.  Keep the
  ;; active selection command aligned with the helper window policy.
  (with-eval-after-load 'dired
    (evil-define-key* '(normal motion) dired-mode-map
      (kbd "RET") #'sk/window-dired-open
      [return] #'sk/window-dired-open))
  (with-eval-after-load 'ibuffer
    (evil-define-key* '(normal motion) ibuffer-mode-map
      (kbd "RET") #'sk/window-ibuffer-visit-buffer
      [return] #'sk/window-ibuffer-visit-buffer))
  (with-eval-after-load 'xref
    (evil-define-key* '(normal motion) sk/window-xref-navigation-mode-map
      (kbd "RET") #'sk/window-xref-goto-xref
      [return] #'sk/window-xref-goto-xref))
  (with-eval-after-load 'flycheck
    (evil-define-key* '(normal motion) flycheck-error-list-mode-map
      (kbd "RET") #'sk/window-flycheck-error-list-goto-error
      [return] #'sk/window-flycheck-error-list-goto-error)))

(with-eval-after-load 'treemacs
  (setq treemacs-position 'left
        treemacs-width 35
        treemacs-is-never-other-window t
        treemacs-width-is-initially-locked t)
  (define-key treemacs-mode-map (kbd "RET") #'sk/window-treemacs-RET-action)
  (define-key treemacs-mode-map [return] #'sk/window-treemacs-RET-action)
  (define-key treemacs-mode-map (kbd "l") #'sk/window-treemacs-RET-action)
  (with-eval-after-load 'evil
    ;; Evil normal-state maps shadow Treemacs' local map in terminal frames.
    (evil-define-key* '(normal motion) treemacs-mode-map
      (kbd "RET") #'sk/window-treemacs-RET-action
      [return] #'sk/window-treemacs-RET-action
      (kbd "l") #'sk/window-treemacs-RET-action)))

(defun sk/window-normalize-full-frame-window ()
  "Clear side-window parameters from the selected full-frame window."
  (sk/window-clear-side-state (selected-window)))

(defun sk/window-toggle-full-frame ()
  "Toggle the selected window between full-frame and the previous layout."
  (interactive)
  (let ((configuration (frame-parameter nil 'sk/full-frame-window-configuration)))
    (if configuration
        (progn
          (set-frame-parameter nil 'sk/full-frame-window-configuration nil)
          (set-window-configuration configuration)
          (message "Restored window layout"))
      (when (minibufferp (current-buffer))
        (user-error "Cannot full-frame the minibuffer"))
      (set-frame-parameter nil 'sk/full-frame-window-configuration
                           (current-window-configuration))
      (let ((buffer (current-buffer))
            (point (point))
            (ignore-window-parameters t))
        (delete-other-windows (selected-window))
        (sk/window-normalize-full-frame-window)
        (switch-to-buffer buffer)
        (goto-char (min point (point-max)))
        (message "Full-frame %s" (buffer-name buffer))))))

(defvar sk/window-owned-display-buffer-rules nil
  "Exact display rules installed by the GuixPC window policy.")

(defvar sk/window-display-buffer-rules nil
  "Current GuixPC rules prepended to `display-buffer-alist'.")

(defvar sk/window-display-policy-migrated nil
  "Non-nil after removing the pre-ownership project display rules once.")

(defconst sk/window-legacy-display-buffer-rules
  '(((derived-mode . treemacs-mode)
     (display-buffer-reuse-window display-buffer-in-side-window)
     (side . left)
     (slot . 0)
     (window-width . 35)
     (reusable-frames . nil)
     (inhibit-switch-frame . t)
     (window-parameters . ((no-delete-other-windows . t))))
    ((or (derived-mode . help-mode)
         "\\*\\(?:Help\\|Apropos\\|eldoc\\)\\*")
     (display-buffer-reuse-window
      display-buffer-reuse-mode-window
      display-buffer-in-side-window)
     (side . right)
     (slot . 1)
     (window-width . 0.42)
     (mode . (help-mode helpful-mode))
     (reusable-frames . nil)
     (inhibit-switch-frame . t)
     (window-parameters . ((no-delete-other-windows . t))))
    ((or "\\*Ibuffer\\*"
         (derived-mode . ibuffer-mode)
         (derived-mode . dired-mode)
         (derived-mode . xref--xref-buffer-mode)
         (derived-mode . magit-mode)
         (derived-mode . eshell-mode)
         (derived-mode . shell-mode)
         (derived-mode . term-mode)
         (derived-mode . vterm-mode))
     (display-buffer-reuse-window
      display-buffer-reuse-mode-window
      display-buffer-in-side-window)
     (side . right)
     (slot . 0)
     (window-width . 0.42)
     (mode . (ibuffer-mode dired-mode xref--xref-buffer-mode magit-mode
              eshell-mode shell-mode term-mode vterm-mode))
     (reusable-frames . nil)
     (inhibit-switch-frame . t)
     (window-parameters . ((no-delete-other-windows . t))))
    ("\\*\\(?:Warnings\\|Compile-Log\\|compilation\\)\\*"
     (display-buffer-reuse-window display-buffer-in-side-window)
     (side . bottom)
     (slot . 0)
     (window-height . 0.28)
     (reusable-frames . nil)
     (inhibit-switch-frame . t)
     (window-parameters . ((no-delete-other-windows . t)))))
  "Exact former project rules migrated into explicit ownership once.")

(defun sk/window-legacy-display-buffer-rule-p (rule)
  "Return non-nil when RULE belongs to the pre-ownership project policy."
  (member rule sk/window-legacy-display-buffer-rules))

(defun sk/window-install-display-buffer-rules (rules)
  "Install project-owned RULES while preserving foreign display rules."
  (let ((foreign-rules
         (seq-remove
          (lambda (rule)
            (memq rule sk/window-owned-display-buffer-rules))
          display-buffer-alist)))
    (unless sk/window-display-policy-migrated
      (setq foreign-rules
            (seq-remove #'sk/window-legacy-display-buffer-rule-p
                        foreign-rules)
            sk/window-display-policy-migrated t))
    (setq display-buffer-alist (append rules foreign-rules)))
  (setq sk/window-owned-display-buffer-rules rules))

(setq sk/window-display-buffer-rules
      `(((derived-mode . treemacs-mode)
         (display-buffer-reuse-window display-buffer-in-side-window)
         (side . left)
         (slot . 0)
         (window-width . 35)
         (reusable-frames . nil)
         (inhibit-switch-frame . t)
         (window-parameters . ((no-delete-other-windows . t))))
        ((or (derived-mode . help-mode)
             "\\*\\(?:Help\\|Apropos\\|eldoc\\)\\*")
         (display-buffer-reuse-window
          display-buffer-reuse-mode-window
          display-buffer-in-side-window)
         (side . right)
         (slot . 1)
         (window-width . 0.42)
         (mode . (help-mode helpful-mode))
         (reusable-frames . nil)
         (inhibit-switch-frame . t)
         (window-parameters . ((no-delete-other-windows . t))))
        ((or "\\*Ibuffer\\*"
             ,(regexp-quote sk/window-xref-buffer-name)
             (derived-mode . ibuffer-mode)
             (derived-mode . dired-mode)
             (derived-mode . magit-mode)
             (derived-mode . eshell-mode)
             (derived-mode . shell-mode)
             (derived-mode . term-mode)
             (derived-mode . vterm-mode))
         (display-buffer-reuse-window
          display-buffer-reuse-mode-window
          display-buffer-in-side-window)
         (side . right)
         (slot . 0)
         (window-width . 0.42)
         (mode . (ibuffer-mode dired-mode magit-mode
                  eshell-mode shell-mode term-mode vterm-mode))
         (reusable-frames . nil)
         (inhibit-switch-frame . t)
         (window-parameters . ((no-delete-other-windows . t))))
        ("\\*\\(?:Warnings\\|Compile-Log\\|compilation\\)\\*"
         (display-buffer-reuse-window display-buffer-in-side-window)
         (side . bottom)
         (slot . 0)
         (window-height . 0.28)
         (reusable-frames . nil)
         (inhibit-switch-frame . t)
         (window-parameters . ((no-delete-other-windows . t))))))

(sk/window-install-display-buffer-rules sk/window-display-buffer-rules)

;; Compatibility names kept while callers move to the policy API.
(defalias 'sk/display-buffer-right #'sk/window-display-right)
(defalias 'sk/display-buffer-bottom #'sk/window-display-bottom)
(defalias 'sk/open-dired #'sk/window-open-dired)
(defalias 'sk/open-ibuffer #'sk/window-open-ibuffer)
(defalias 'sk/display-magit-buffer #'sk/window-display-magit-buffer)
(defalias 'sk/normalize-full-frame-window #'sk/window-normalize-full-frame-window)
(defalias 'sk/toggle-window-full-frame #'sk/window-toggle-full-frame)

(provide 'sk-window-policy)

;;; sk-window-policy.el ends here
