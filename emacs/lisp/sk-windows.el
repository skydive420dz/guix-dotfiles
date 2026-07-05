;;; sk-windows.el --- Display policy for utility buffers -*- lexical-binding: t; -*-

(defun sk/display-buffer-right (buffer &optional width)
  "Display BUFFER in a right side utility window.
WIDTH defaults to a compact panel width."
  (display-buffer-in-side-window
   buffer
   `((side . right)
     (slot . 0)
     (window-width . ,(or width 0.42))
     (window-parameters . ((no-delete-other-windows . t))))))

(defun sk/display-buffer-bottom (buffer &optional height)
  "Display BUFFER in a bottom side utility window.
HEIGHT defaults to a compact panel height."
  (display-buffer-in-side-window
   buffer
   `((side . bottom)
     (slot . 0)
     (window-height . ,(or height 0.28))
     (window-parameters . ((no-delete-other-windows . t))))))

(defun sk/open-dired (&optional prompt)
  "Open Dired for `default-directory' in the utility side window.
With PROMPT, ask for a directory."
  (interactive "P")
  (let* ((directory (if prompt
                        (read-directory-name "Dired: " nil nil t)
                      default-directory))
         (buffer (dired-noselect directory))
         (window (sk/display-buffer-right buffer)))
    (select-window window)))

(defun sk/open-ibuffer ()
  "Open Ibuffer in the utility side window."
  (interactive)
  (ibuffer nil "*Ibuffer*" nil t)
  (when-let* ((buffer (get-buffer "*Ibuffer*"))
              (window (sk/display-buffer-right buffer)))
    (select-window window)))

(defun sk/display-magit-buffer (buffer)
  "Display Magit BUFFER in the utility side window."
  (sk/display-buffer-right buffer 0.48))

(defun sk/normalize-full-frame-window ()
  "Clear side-window parameters from the selected full-frame window."
  (set-window-dedicated-p nil nil)
  (dolist (parameter '(window-side window-slot no-delete-other-windows))
    (set-window-parameter nil parameter nil)))

(defun sk/toggle-window-full-frame ()
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
        (sk/normalize-full-frame-window)
        (switch-to-buffer buffer)
        (goto-char (min point (point-max)))
        (message "Full-frame %s" (buffer-name buffer))))))

(setq display-buffer-alist
      '(((or (derived-mode . help-mode)
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
             (derived-mode . term-mode))
         (display-buffer-reuse-window
          display-buffer-reuse-mode-window
          display-buffer-in-side-window)
         (side . right)
         (slot . 0)
         (window-width . 0.42)
         (mode . (ibuffer-mode dired-mode xref--xref-buffer-mode magit-mode
                  eshell-mode shell-mode term-mode))
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

(provide 'sk-windows)

;;; sk-windows.el ends here
