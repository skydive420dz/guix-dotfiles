(add-to-list 'load-path
             (expand-file-name "lisp" (file-name-directory
                                       (file-truename
                                        (or load-file-name buffer-file-name)))))

(require 'sk-exwm)

(sk/exwm-start)
