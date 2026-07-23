;;; Declarative GuixPC desktop-integration ownership.

(define-module (sk desktop-integration)
  #:use-module (gnu home services)
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
    ("text/plain" . "sk-emacsclient-files.desktop")
    ("text/markdown" . "sk-emacsclient-files.desktop")
    ("text/x-lisp" . "sk-emacsclient-files.desktop")
    ("text/x-scheme" . "sk-emacsclient-files.desktop")
    ("text/x-shellscript" . "sk-emacsclient-files.desktop")
    ("application/x-shellscript" . "sk-emacsclient-files.desktop")
    ("text/x-script.python" . "sk-emacsclient-files.desktop")
    ("application/json" . "sk-emacsclient-files.desktop")
    ("inode/directory" . "sk-emacsclient-files.desktop")
    ("x-scheme-handler/org-protocol"
     . "sk-emacsclient-org-protocol.desktop")
    ("x-scheme-handler/mailto" . "sk-emacsclient-mail.desktop")))

(define (sk:emacsclient-file-desktop-entry emacs)
  "Return a shell-free desktop entry that reuses the running Emacs server."
  (mixed-text-file
   "sk-emacsclient-files.desktop"
   "[Desktop Entry]\n"
   "Version=1.0\n"
   "Type=Application\n"
   "Name=Emacs (EXWM Client)\n"
   "GenericName=Text Editor\n"
   "Comment=Reuse the running EXWM Emacs server\n"
   "Exec="
   (file-append emacs "/bin/emacsclient")
   " --socket-name=server --alternate-editor=false"
   " --no-wait --reuse-frame -- %F\n"
   "TryExec="
   (file-append emacs "/bin/emacsclient")
   "\n"
   "Icon=emacs\n"
   "Terminal=false\n"
   "NoDisplay=true\n"
   "StartupNotify=false\n"
   "MimeType=text/plain;text/markdown;text/x-lisp;text/x-scheme;"
   "text/x-shellscript;application/x-shellscript;text/x-script.python;"
   "application/json;inode/directory;\n"))

(define (sk:emacsclient-org-protocol-desktop-entry emacs)
  "Return the dedicated Org protocol entry.

The URL field code must remain separate from the file entry: Emacsclient does
not normalize file:// URLs into local paths."
  (mixed-text-file
   "sk-emacsclient-org-protocol.desktop"
   "[Desktop Entry]\n"
   "Version=1.0\n"
   "Type=Application\n"
   "Name=Emacs Org Protocol (Client)\n"
   "Comment=Send an Org protocol URL to the running Emacs server\n"
   "Exec="
   (file-append emacs "/bin/emacsclient")
   " --socket-name=server --alternate-editor=false"
   " --no-wait -- %u\n"
   "TryExec="
   (file-append emacs "/bin/emacsclient")
   "\n"
   "Icon=emacs\n"
   "Terminal=false\n"
   "NoDisplay=true\n"
   "StartupNotify=false\n"
   "MimeType=x-scheme-handler/org-protocol;\n"))

(define (sk:emacsclient-mail-handler emacs)
  "Return a Guile launcher that passes one safely quoted mailto URI to Emacs."
  (program-file
   "sk-emacsclient-mail"
   #~(begin
       (use-modules (ice-9 format)
                    (ice-9 match))
       (match (command-line)
         ((_ uri)
          (execl #$(file-append emacs "/bin/emacsclient")
                 "emacsclient"
                 "--socket-name=server"
                 "--alternate-editor=false"
                 "--no-wait"
                 "--eval"
                 "(message-mailto (pop server-eval-args-left))"
                 uri))
         (_
          (format (current-error-port)
                  "usage: sk-emacsclient-mail MAILTO-URI~%")
          (exit 64))))))

(define (sk:emacsclient-mail-desktop-entry emacs)
  "Return the shell-free mailto desktop entry for the running Emacs server."
  (let ((handler (sk:emacsclient-mail-handler emacs)))
    (mixed-text-file
     "sk-emacsclient-mail.desktop"
     "[Desktop Entry]\n"
     "Version=1.0\n"
     "Type=Application\n"
     "Name=Emacs Mail (Client)\n"
     "Comment=Compose mail in the running Emacs server\n"
     "Exec=" handler " %u\n"
     "TryExec=" handler "\n"
     "Icon=emacs\n"
     "Terminal=false\n"
     "NoDisplay=true\n"
     "StartupNotify=false\n"
     "MimeType=x-scheme-handler/mailto;\n")))

(define (sk:emacsclient-xdg-data-files emacs)
  "Return C3 desktop entries backed by the exact Home Emacs package."
  `(("applications/sk-emacsclient-files.desktop"
     ,(sk:emacsclient-file-desktop-entry emacs))
    ("applications/sk-emacsclient-org-protocol.desktop"
     ,(sk:emacsclient-org-protocol-desktop-entry emacs))
    ("applications/sk-emacsclient-mail.desktop"
     ,(sk:emacsclient-mail-desktop-entry emacs))))

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

(define (sk:desktop-integration-home-services emacs polkit-agent)
  "Return C3 Home services using exact EMACS and POLKIT-AGENT packages."
  (list
   (service home-x11-service-type 30)
   (simple-service
    'sk-emacsclient-xdg-data
    home-xdg-data-files-service-type
    (sk:emacsclient-xdg-data-files emacs))
   (service
    home-xdg-mime-applications-service-type
    (home-xdg-mime-applications-configuration
     (added
      '(("inode/directory" . "sk-emacsclient-files.desktop")))
     (default %sk-desktop-mime-defaults)))
   (simple-service
    'sk-polkit-agent
    home-shepherd-service-type
    (list (sk:polkit-agent-shepherd-service polkit-agent)))))
