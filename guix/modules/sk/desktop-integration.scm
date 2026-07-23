;;; Declarative GuixPC desktop-integration ownership.

(define-module (sk desktop-integration)
  #:use-module (gnu home services desktop)
  #:use-module (gnu home services shepherd)
  #:use-module (gnu home services xdg)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:export (%sk-desktop-mime-defaults
            sk:polkit-agent-shepherd-service
            sk:desktop-integration-home-services))

(define %sk-desktop-mime-defaults
  '(("x-scheme-handler/http" . "chromium.desktop")
    ("x-scheme-handler/https" . "chromium.desktop")
    ("text/html" . "chromium.desktop")
    ("application/xhtml+xml" . "chromium.desktop")
    ("application/pdf" . "chromium.desktop")
    ("image/png" . "chromium.desktop")
    ("image/jpeg" . "chromium.desktop")
    ("image/gif" . "chromium.desktop")
    ("image/webp" . "chromium.desktop")
    ("image/svg+xml" . "chromium.desktop")
    ("text/plain" . "emacsclient.desktop")
    ("text/markdown" . "emacsclient.desktop")
    ("text/x-lisp" . "emacsclient.desktop")
    ("text/x-scheme" . "emacsclient.desktop")
    ("text/x-shellscript" . "emacsclient.desktop")
    ("application/x-shellscript" . "emacsclient.desktop")
    ("text/x-script.python" . "emacsclient.desktop")
    ("application/json" . "emacsclient.desktop")
    ("inode/directory" . "emacsclient.desktop")
    ("x-scheme-handler/org-protocol" . "emacsclient.desktop")
    ("x-scheme-handler/mailto" . "emacsclient-mail.desktop")))

(define (sk:polkit-agent-shepherd-service polkit-agent)
  "Return the single GTK PolicyKit authentication-agent service.

POLKIT-AGENT is the package that supplies the GNOME authentication agent.
The start thunk deliberately reads DISPLAY after the x11-display requirement
has set Shepherd's environment; constructing it earlier captures a stale or
missing display."
  (shepherd-service
   (documentation "Run the GTK PolicyKit authentication agent for EXWM.")
   (provision '(polkit-agent))
   (requirement '(dbus x11-display))
   (modules '((shepherd support)
              (srfi srfi-1)
              (srfi srfi-13)))
   (start
    #~(lambda ()
        (let* ((display (getenv "DISPLAY"))
               (home (getenv "HOME"))
               (runtime-directory
                (or (getenv "XDG_RUNTIME_DIR")
                    (format #f "/run/user/~a" (getuid))))
               (xauthority
                (or (getenv "XAUTHORITY")
                    (and home (string-append home "/.Xauthority")))))
          (unless display
            (error "PolicyKit agent cannot start without an X11 display"))
          (unless home
            (error "PolicyKit agent cannot start without HOME"))
          ((make-forkexec-constructor
            (list
             #$(file-append
                polkit-agent
                "/libexec/polkit-gnome-authentication-agent-1"))
            #:environment-variables
            (cons*
             (string-append "DISPLAY=" display)
             (string-append "XAUTHORITY=" xauthority)
             (string-append
              "DBUS_SESSION_BUS_ADDRESS=unix:path="
              runtime-directory
              "/bus")
             (remove
              (lambda (entry)
                (or (string-prefix? "DISPLAY=" entry)
                    (string-prefix? "XAUTHORITY=" entry)
                    (string-prefix? "DBUS_SESSION_BUS_ADDRESS=" entry)))
              (default-environment-variables)))
            #:log-file
            (string-append %user-log-dir "/polkit-agent.log"))))))
   (stop #~(make-kill-destructor))
   (respawn? #t)
   (respawn-delay 5)))

(define (sk:desktop-integration-home-services polkit-agent)
  "Return C3 Home services using POLKIT-AGENT as the GTK agent package."
  (list
   (service home-x11-service-type 30)
   (service
    home-xdg-mime-applications-service-type
    (home-xdg-mime-applications-configuration
     (added '(("inode/directory" . "emacsclient.desktop")))
     (default %sk-desktop-mime-defaults)))
   (simple-service
    'sk-polkit-agent
    home-shepherd-service-type
    (list (sk:polkit-agent-shepherd-service polkit-agent)))))
