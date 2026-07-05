(require 'exwm)

(defvar sk/wallpaper-file
  (expand-file-name "~/Projects/guix-dotfiles/assets/wallpapers/sky.png"))

(defun sk/set-wallpaper ()
  (interactive)
  (when (and (executable-find "xwallpaper")
             (file-exists-p sk/wallpaper-file))
    (start-process "xwallpaper" nil
                   "xwallpaper" "--zoom" sk/wallpaper-file)))

(exwm-input-set-key (kbd "s-<return>")
                    (lambda ()
                      (interactive)
                      (start-process-shell-command "kitty" nil "kitty")))

(exwm-input-set-key (kbd "s-w")
                    (lambda ()
                      (interactive)
                      (start-process-shell-command
                       "browser" nil "chromium")))

(defun sk/volume-raise ()
  (interactive)
  (start-process "wpctl-volume-up" nil
		 "wpctl" "set volume" "-l" "1.0"
		 "@DEFAULT_AUDIO_SINK@" "5%+"))

(defun sk/volume-lower ()
  (interactive)
  (start-process "wpctl-volume-down" nil
		 "wpctl" "set volume"
		 "@DEFAULT_AUDIO_SINK@" "5%-"))

(exwm-input-set-key (kbd "<XF86AudioRaiseVolume>") #'sk/volume-raise)
(exwm-input-set-key (kbd "<XF86AudioLowerVolume>") #'sk/volume-lower)


(sk/set-wallpaper)

(exwm-wm-mode)
