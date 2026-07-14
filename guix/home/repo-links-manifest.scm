;; Project-owned paths that remain live symlinks into the checkout.

(define %guixpc-repo-links
  '((".bash_profile" "shell/bash_profile")
    (".bashrc" "shell/bashrc")
    (".zprofile" "shell/zprofile")
    (".xinitrc" "shell/xinitrc")
    (".exwm" "emacs/exwm-loader.el")
    (".emacs.d/early-init.el" "emacs/early-init.el")
    (".emacs.d/init.el" "emacs/init.el")
    (".emacs.d/exwm.el" "emacs/exwm.el")
    (".gdbinit" "gdb/gdbinit")
    (".guile" "guile/guile")
    (".Xdefaults" "x11/Xdefaults")
    (".config/kitty/kitty.conf" "kitty/kitty.conf")
    (".config/ranger/rc.conf" "ranger/rc.conf")
    (".config/ranger/rifle.conf" "ranger/rifle.conf")
    (".config/ranger/scope.sh" "ranger/scope.sh")))
