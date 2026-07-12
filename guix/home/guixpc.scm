;; User-level services for guixpc.
;;
;; The system configuration owns hardware services and system packages.
;; Guix Home owns session services such as PipeWire.

(use-modules (gnu home)
             (gnu home services)
             (gnu home services desktop)
             (gnu home services shells)
             (gnu home services sound)
             (gnu services)
             (guix gexp))

(define %repo-root
  (dirname (dirname (dirname (current-filename)))))

(define %repo-link-helper
  (local-file (string-append (dirname (current-filename)) "/repo-links.scm")
              "sk-repo-links.scm"))

(define %repo-link-activation
  #~(begin
      (define home (getenv "HOME"))
      (define repo #$%repo-root)
      (primitive-load #$%repo-link-helper)
      ((module-ref (current-module) 'sk:activate-repo-links)
       home
       repo
       '((".bash_profile" "shell/bash_profile")
         (".bashrc" "shell/bashrc")
         (".zprofile" "shell/zprofile")
         (".xinitrc" "shell/xinitrc")
         (".exwm" "emacs/exwm-loader.el")
         (".emacs.d/init.el" "emacs/init.el")
         (".emacs.d/exwm.el" "emacs/exwm.el")
         (".gdbinit" "gdb/gdbinit")
         (".guile" "guile/guile")
         (".Xdefaults" "x11/Xdefaults")
         (".config/kitty/kitty.conf" "kitty/kitty.conf")
         (".config/ranger/rc.conf" "ranger/rc.conf")
         (".config/ranger/rifle.conf" "ranger/rifle.conf")
         (".config/ranger/scope.sh" "ranger/scope.sh")))))

(home-environment
 (services
  (list
   (simple-service 'sk-repo-dotfile-links
                   home-activation-service-type
                   %repo-link-activation)
   (service home-fish-service-type
            (home-fish-configuration
             (config (list (local-file "../../shell/config.fish"
                                       "sk-fish-config.fish")))
             (aliases
              '(("ls" . "ls -p --color=auto")
                ("ll" . "ls -l")
                ("grep" . "grep --color=auto")
                ("gsr" . "$HOME/Projects/guix-dotfiles/scripts/guix-reconfigure system")
                ("ghr" . "$HOME/Projects/guix-dotfiles/scripts/guix-reconfigure home")))))
   (service home-dbus-service-type)
   (service home-pipewire-service-type
            (home-pipewire-configuration
             (enable-pulseaudio? #t))))))
