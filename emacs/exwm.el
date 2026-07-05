(require 'exwm)
(require 'subr-x)

(autoload 'counsel-linux-apps-list "counsel")

(defun sk/exwm-launch-app ()
  (interactive)
  (require 'counsel)
  (ivy-read "Run application: " (counsel-linux-apps-list)
            :require-match t
            :action #'sk/exwm-launch-desktop-entry
            :caller 'sk/exwm-launch-app))

(defun sk/exwm-launch-desktop-entry (desktop-shortcut)
  (let* ((desktop-id (cdr desktop-shortcut))
         (launcher (or (executable-find "gtk-launch")
                       (executable-find "gtk4-launch"))))
    (if launcher
        (call-process launcher nil 0 nil desktop-id)
      (sk/exwm-launch-desktop-entry-direct desktop-id))))

(defun sk/exwm-launch-desktop-entry-direct (desktop-id)
  (let* ((desktop-file (cdr (assoc desktop-id (counsel-linux-apps-list-desktop-files))))
         (exec (and desktop-file (sk/desktop-entry-value desktop-file "Exec")))
         (terminal (string-equal
                    (downcase (or (and desktop-file
                                       (sk/desktop-entry-value desktop-file "Terminal"))
                                  "false"))
                    "true"))
         (args (and exec (split-string-and-unquote
                          (sk/desktop-entry-clean-exec exec)))))
    (unless args
      (user-error "No Exec line found for %s" desktop-id))
    (if terminal
        (unless (executable-find "kitty")
          (user-error "Terminal app needs kitty: %s" desktop-id))
      (unless (executable-find (car args))
        (user-error "Executable not found: %s" (car args))))
    (if terminal
        (apply #'start-process desktop-id nil "kitty" "--" args)
      (apply #'start-process desktop-id nil args))))

(defun sk/desktop-entry-value (desktop-file key)
  (with-temp-buffer
    (insert-file-contents desktop-file)
    (goto-char (point-min))
    (when (re-search-forward "^\\[Desktop Entry\\]$" nil t)
      (let ((limit (save-excursion
                     (or (and (re-search-forward "^\\[" nil t)
                              (match-beginning 0))
                         (point-max)))))
        (when (re-search-forward
               (format "^%s *= *\\(.+\\)$" (regexp-quote key))
               limit t)
          (match-string 1))))))

(defun sk/desktop-entry-clean-exec (exec)
  (let ((clean (replace-regexp-in-string "%%" "__SK_PERCENT__" exec t t)))
    (setq clean (replace-regexp-in-string "%[fFuUdDnNickvm]" "" clean t t))
    (string-trim
     (replace-regexp-in-string "__SK_PERCENT__" "%" clean t t))))

(exwm-input-set-key (kbd "s-SPC") #'sk/exwm-launch-app)

(defun sk/set-keyboard-repeat ()
  (interactive)
  (when (executable-find "xset")
    (start-process "xset-repeat" nil
                   "xset" "r" "rate" "210" "67")))

(defvar sk/wallpaper-file
  (expand-file-name "~/Projects/guix-dotfiles/assets/wallpapers/sky.png"))

(defun sk/set-wallpaper ()
  (interactive)
  (when (and (executable-find "xwallpaper")
             (file-exists-p sk/wallpaper-file))
    (start-process "xwallpaper" nil
                   "xwallpaper" "--zoom" sk/wallpaper-file)))

(defun sk/exwm-launch-kitty ()
  (interactive)
  (start-process-shell-command "kitty" nil "kitty")
  (message "Launching kitty"))

(defun sk/exwm-launch-browser ()
  (interactive)
  (start-process-shell-command "browser" nil "chromium")
  (message "Launching chromium"))

(defun sk/exwm-reload ()
  (interactive)
  (load-file "~/.emacs.d/exwm.el")
  (message "EXWM config reloaded"))

(defun sk/exwm-update-title ()
  (exwm-workspace-rename-buffer
   (string-trim
    (format "%s%s%s"
            (or exwm-class-name "EXWM")
            (if (and exwm-title (not (string-empty-p exwm-title))) ": " "")
            (or exwm-title "")))))

(add-hook 'exwm-update-class-hook #'sk/exwm-update-title)
(add-hook 'exwm-update-title-hook #'sk/exwm-update-title)

(exwm-input-set-key (kbd "s-<return>") #'sk/exwm-launch-kitty)
(exwm-input-set-key (kbd "s-w") #'sk/exwm-launch-browser)
(exwm-input-set-key (kbd "s-r") #'sk/exwm-reload)

(defun sk/volume-raise ()
  (interactive)
  (start-process "wpctl-volume-up" nil
		 "wpctl" "set-volume" "-l" "1.0"
		 "@DEFAULT_AUDIO_SINK@" "5%+"))

(defun sk/volume-lower ()
  (interactive)
  (start-process "wpctl-volume-down" nil
		 "wpctl" "set-volume"
		 "@DEFAULT_AUDIO_SINK@" "5%-"))

(exwm-input-set-key (kbd "<XF86AudioRaiseVolume>") #'sk/volume-raise)
(exwm-input-set-key (kbd "<XF86AudioLowerVolume>") #'sk/volume-lower)


(sk/set-wallpaper)
(sk/set-keyboard-repeat)

(exwm-wm-mode)
