(require 'exwm)

(exwm-input-set-key (kbd "s-<return>")
                    (lambda ()
                      (interactive)
                      (start-process-shell-command "kitty" nil "kitty")))
(exwm-wm-mode)

(exwm-input-set-key (kbd "s-w")
		    (lambda ()
		      (interactive)
		      (start-process-shell-command
		       "browser" nil "chromium")))
