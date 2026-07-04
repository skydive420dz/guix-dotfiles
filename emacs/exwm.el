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

(sk/set-wallpaper)

(exwm-wm-mode)
