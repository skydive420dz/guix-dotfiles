(require 'exwm)
(require 'subr-x)

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

(exwm-wm-mode)
