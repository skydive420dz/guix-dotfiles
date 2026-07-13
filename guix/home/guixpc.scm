;; User-level services for guixpc.
;;
;; The system configuration owns hardware services and system packages.
;; Guix Home owns session services such as PipeWire.

(use-modules (gnu home)
             (gnu home services)
             (gnu home services desktop)
             (gnu home services shells)
             (gnu home services sound)
             (gnu packages)
             (gnu services)
             (guix gexp)
             (guix packages))

(load (string-append (dirname (current-filename))
                     "/../package-ownership.scm"))

(define %repo-root
  (dirname (dirname (dirname (current-filename)))))

(define %repo-link-helper
  (local-file (string-append (dirname (current-filename)) "/repo-links.scm")
              "sk-repo-links.scm"))

(define %repo-link-manifest
  (local-file
   (string-append (dirname (current-filename)) "/repo-links-manifest.scm")
   "sk-repo-links-manifest.scm"))

(define %repo-link-activation
  #~(begin
      (define home (getenv "HOME"))
      (define repo #$%repo-root)
      (primitive-load #$%repo-link-helper)
      (primitive-load #$%repo-link-manifest)
      ((module-ref (current-module) 'sk:activate-repo-links)
       home
       repo
       (module-ref (current-module) '%guixpc-repo-links))))

(home-environment
 (packages
  (map specification->package %guixpc-home-package-specifications))
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
