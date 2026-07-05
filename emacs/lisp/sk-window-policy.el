;;; sk-window-policy.el --- Shared window and panel policy -*- lexical-binding: t; -*-

(require 'subr-x)

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
  (ibuffer nil "*Ibuffer*" nil t)
  (when-let* ((buffer (get-buffer "*Ibuffer*"))
              (window (sk/window-display-right buffer)))
    (select-window window)))

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
  (let ((xref (xref--item-at-point)))
    (unless xref
      (user-error "No xref at point"))
    (select-window (sk/window-main-window))
    (xref--show-location (xref-item-location xref) t)))

(with-eval-after-load 'dired
  (define-key dired-mode-map (kbd "RET") #'sk/window-dired-open))

(with-eval-after-load 'ibuffer
  (define-key ibuffer-mode-map (kbd "RET") #'sk/window-ibuffer-visit-buffer))

(with-eval-after-load 'xref
  (define-key xref--xref-buffer-mode-map (kbd "RET") #'sk/window-xref-goto-xref))

(with-eval-after-load 'treemacs
  (setq treemacs-position 'left
        treemacs-width 35
        treemacs-is-never-other-window t
        treemacs-width-is-initially-locked t))

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

(setq display-buffer-alist
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
        ((or (derived-mode . ibuffer-mode)
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
         (window-parameters . ((no-delete-other-windows . t))))))

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
