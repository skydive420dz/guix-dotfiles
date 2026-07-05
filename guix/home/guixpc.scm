;; User-level services for guixpc.
;;
;; The system configuration owns hardware services and system packages.
;; Guix Home owns session services such as PipeWire.

(use-modules (gnu home)
             (gnu home services)
             (gnu home services desktop)
             (gnu home services sound)
             (gnu services)
             (guix gexp))

(define %repo-root
  (dirname (dirname (dirname (current-filename)))))

(define %repo-link-activation
  #~(begin
      (use-modules ((guix build utils) #:select (mkdir-p)))

      (define home (getenv "HOME"))
      (define repo #$%repo-root)

      (define (symlink-path? path)
        (let ((stat (false-if-exception (lstat path))))
          (and stat
               (eq? (stat:type stat) 'symlink))))

      (define (ensure-repo-link target source)
        (let* ((target-path (string-append home "/" target))
               (source-path (string-append repo "/" source))
               (parent (dirname target-path)))
          (mkdir-p parent)
          (cond
           ((and (symlink-path? target-path)
                 (string=? (readlink target-path) source-path))
            #t)
           ((symlink-path? target-path)
            (delete-file target-path)
            (symlink source-path target-path)
            (format #t "Updated symlink ~a -> ~a~%" target-path source-path))
           ((not (file-exists? target-path))
            (symlink source-path target-path)
            (format #t "Created symlink ~a -> ~a~%" target-path source-path))
           (else
            (format #t "Keeping existing non-symlink ~a~%" target-path)))))

      (for-each
       (lambda (link)
         (ensure-repo-link (car link) (cadr link)))
       '((".bash_profile" "shell/bash_profile")
         (".bashrc" "shell/bashrc")
         (".zprofile" "shell/zprofile")
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
   (service home-dbus-service-type)
   (service home-pipewire-service-type
            (home-pipewire-configuration
             (enable-pulseaudio? #t))))))
