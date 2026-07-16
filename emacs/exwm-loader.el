(when (fboundp 'sk/startup-trace-mark)
  (sk/startup-trace-mark "exwm-loader-enter"))

(if (fboundp 'sk/startup-trace-call)
    (sk/startup-trace-call "load:~/.emacs.d/exwm.el"
                           #'load-file "~/.emacs.d/exwm.el")
  (load-file "~/.emacs.d/exwm.el"))

(when (fboundp 'sk/startup-trace-mark)
  (sk/startup-trace-mark "exwm-loader-exit"))
