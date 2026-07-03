(require 'exwm)

(exwm-input-set-key (kbd "s-RET")
                    (lambda ()
                      (interactive)
                      (start-process-shell-command "kitty" nil "kitty")))
(exwm-wm-mode)
