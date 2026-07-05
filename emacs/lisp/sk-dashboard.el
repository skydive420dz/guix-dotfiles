;;; sk-dashboard.el --- Sky home buffer -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'seq)

(defconst sk/dashboard-buffer-name "*Sky Home*"
  "Name of the Sky home buffer.")

(defconst sk/dashboard-logo-file
  (expand-file-name "assets/skydive420dz.svg" sk/user-directory)
  "Logo shown in the Sky home buffer.")

(defun sk/dashboard--insert-left-text (text &optional face)
  "Insert TEXT near the left edge, optionally using FACE."
  (insert "  ")
  (insert (if face (propertize text 'face face) text))
  (insert "\n"))

(defun sk/dashboard--insert-logo (image)
  "Insert dashboard IMAGE near the top-left edge."
  (insert "  ")
  (insert-image image)
  (insert "\n"))

(defun sk/dashboard--quiet-buffer ()
  "Disable editing affordances that do not belong on the home buffer."
  (setq-local cursor-type nil
              display-line-numbers nil
              display-line-numbers-type nil
              hl-line-mode t)
  (setq-local face-remapping-alist
              (assq-delete-all 'cursor
                               (assq-delete-all 'hl-line
                                                (copy-sequence face-remapping-alist))))
  (tab-line-mode -1)
  (display-line-numbers-mode -1))

(defun sk/dashboard-render ()
  "Render the Sky home buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq-local mode-line-format nil
                truncate-lines t)
    (sk/dashboard--quiet-buffer)
    (let ((image (when (and (display-graphic-p)
                            (file-readable-p sk/dashboard-logo-file)
                            (image-type-available-p 'svg))
                   (ignore-errors
                     (create-image sk/dashboard-logo-file 'svg nil :width 520 :ascent 'center)))))
      (insert "\n")
      (if image
          (sk/dashboard--insert-logo image)
        (sk/dashboard--insert-left-text "Skydive420dz" 'bold)))
    (goto-char (point-min))))

(define-derived-mode sk/dashboard-mode special-mode "Sky"
  "Major mode for the Sky home buffer."
  (setq-local buffer-read-only t)
  (sk/dashboard--quiet-buffer))

(define-key sk/dashboard-mode-map [remap next-line] #'ignore)
(define-key sk/dashboard-mode-map [remap previous-line] #'ignore)
(define-key sk/dashboard-mode-map [remap forward-char] #'ignore)
(define-key sk/dashboard-mode-map [remap backward-char] #'ignore)

(with-eval-after-load 'evil
  (evil-define-key '(normal motion) sk/dashboard-mode-map
    (kbd "h") #'ignore
    (kbd "j") #'ignore
    (kbd "k") #'ignore
    (kbd "l") #'ignore
    (kbd "<down>") #'ignore
    (kbd "<up>") #'ignore
    (kbd "<left>") #'ignore
    (kbd "<right>") #'ignore
    (kbd "i") #'ignore
    (kbd "a") #'ignore
    (kbd "o") #'ignore
    (kbd "O") #'ignore
    (kbd "s") #'ignore
    (kbd "S") #'ignore))

(defun sk/dashboard-buffer ()
  "Return the Sky home buffer, creating it when needed."
  (let ((buffer (get-buffer-create sk/dashboard-buffer-name)))
    (with-current-buffer buffer
      (sk/dashboard-mode)
      (sk/dashboard-render))
    buffer))

(defun sk/dashboard ()
  "Switch to the Sky home buffer."
  (interactive)
  (switch-to-buffer (sk/dashboard-buffer))
  (sk/dashboard--quiet-buffer))

(defun sk/dashboard-buffer-p (&optional buffer)
  "Return non-nil when BUFFER is the Sky home buffer."
  (string= (buffer-name (or buffer (current-buffer))) sk/dashboard-buffer-name))

(defun sk/user-buffer-p (buffer)
  "Return non-nil when BUFFER is a user-facing buffer."
  (let ((name (buffer-name buffer)))
    (and name
         (not (string-prefix-p " " name))
         (not (sk/dashboard-buffer-p buffer)))))

(defun sk/ordinary-buffer-p (buffer)
  "Return non-nil when BUFFER should keep the home buffer hidden."
  (let ((name (buffer-name buffer)))
    (and (buffer-live-p buffer)
         name
         (not (string-prefix-p " " name))
         (not (string-prefix-p "*" name))
         (not (sk/dashboard-buffer-p buffer)))))

(defun sk/show-dashboard-if-no-ordinary-buffers ()
  "Show the Sky home buffer when no ordinary buffers remain."
  (unless (seq-some #'sk/ordinary-buffer-p (buffer-list))
    (sk/dashboard)))

(defun sk/kill-current-buffer ()
  "Kill the current buffer and show the home buffer if nothing ordinary remains."
  (interactive)
  (kill-buffer (current-buffer))
  (sk/show-dashboard-if-no-ordinary-buffers))

(setq initial-buffer-choice #'sk/dashboard-buffer)

(when-let ((buffer (get-buffer sk/dashboard-buffer-name)))
  (with-current-buffer buffer
    (sk/dashboard--quiet-buffer)))

(provide 'sk-dashboard)

;;; sk-dashboard.el ends here
