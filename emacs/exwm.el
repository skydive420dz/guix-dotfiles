(add-to-list 'load-path
             (expand-file-name "lisp" (file-name-directory
                                       (file-truename
                                        (or load-file-name buffer-file-name)))))

(when (fboundp 'sk/startup-trace-mark)
  (sk/startup-trace-mark "exwm-config-enter"))

(require 'sk-exwm)

(if (fboundp 'sk/startup-trace-call)
    (sk/startup-trace-call "sk/exwm-start" #'sk/exwm-start)
  (sk/exwm-start))

(when (fboundp 'sk/startup-trace-mark)
  (sk/startup-trace-mark "exwm-config-exit"))
