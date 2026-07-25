#!/usr/bin/env -S guile --no-auto-compile -s
!#

;;; Read-only, one-level ownership audit for guixpc Home and XDG paths.

(use-modules (ice-9 ftw)
             (ice-9 match)
             (srfi srfi-1)
             (srfi srfi-13))

(define %schema 'sk-home-xdg-audit/v1)

;; PATH CLASS OWNER KIND MODE-POLICY DISPOSITION REQUIRED? TARGET-POLICY
(define %entries
  '(("." durable-local user directory private keep #t #f)
    ("=" unknown unknown regular owned remove-candidate #f #f)
    ("%l\n" unknown unknown regular owned remove-candidate #f #f)
    ("1784329267-guix-home-legacy-configs-backup"
     durable-local user directory owned park #f #f)
    (".bash_history" durable-local application regular private keep #f #f)
    (".bash_profile" declarative repo symlink any keep #t
     (repo "shell/bash_profile"))
    (".bashrc" declarative repo symlink any keep #t (repo "shell/bashrc"))
    (".cache" cache application directory private keep #t #f)
    (".clojure" mixed application directory owned review #f #f)
    (".config" mixed user directory owned keep #t #f)
    (".dbus" legacy application directory private review #f #f)
    ("Documents" durable-synchronized user directory owned keep #t #f)
    ("Downloads" durable-local user directory private keep #f #f)
    (".emacs.d" mixed user directory private migrate-candidate #t #f)
    (".emacs.d/early-init.el" declarative repo symlink any keep #t
     (repo "emacs/early-init.el"))
    (".emacs.d/exwm.el" declarative repo symlink any keep #t
     (repo "emacs/exwm.el"))
    (".emacs.d/init.el" declarative repo symlink any keep #t
     (repo "emacs/init.el"))
    (".exwm" declarative repo symlink any keep #t
     (repo "emacs/exwm-loader.el"))
    (".gdbinit" declarative repo symlink any keep #t (repo "gdb/gdbinit"))
    (".geiser_history.guile"
     durable-local application regular review-private keep #f #f)
    (".gnupg" secret user directory private keep #t #f)
    (".gtkrc-2.0" declarative guix-home symlink any keep #t
     (home-file ".gtkrc-2.0"))
    (".guile" declarative repo symlink any keep #t (repo "guile/guile"))
    (".guile_history" durable-local application regular private keep #f #f)
    (".guix-home" declarative guix-home symlink any keep #t
     (prefix "/gnu/store/"))
    (".lesshst" durable-local application regular private keep #f #f)
    (".local" mixed user directory owned keep #t #f)
    (".profile" declarative guix-home symlink any keep #t
     (home-file ".profile"))
    ("Projects" durable-local user directory owned keep #t #f)
    (".python_history" durable-local application regular private keep #f #f)
    (".ruff_cache" cache application directory owned remove-candidate #f #f)
    (".ssh" secret user directory private keep #t #f)
    (".viminfo" durable-local application regular private keep #f #f)
    (".wget-hsts" durable-local application regular owned keep #f #f)
    (".Xauthority" secret runtime regular private keep #t #f)
    (".Xdefaults" declarative repo symlink any keep #t
     (repo "x11/Xdefaults"))
    (".xinitrc" declarative repo symlink any keep #t
     (repo "shell/xinitrc"))
    (".zprofile" declarative repo symlink any keep #t
     (repo "shell/zprofile"))

    (".config/alsa" declarative guix-home directory owned keep #t #f)
    (".config/alsa/asoundrc" declarative guix-home symlink any keep #t
     (home-file ".config/alsa/asoundrc"))
    (".config/btop" durable-local application directory owned keep #f #f)
    (".config/chromium" durable-local application directory private keep #t #f)
    (".config/dunst" declarative guix-home directory owned keep #t #f)
    (".config/dunst/dunstrc" declarative guix-home symlink any keep #t
     (home-file ".config/dunst/dunstrc"))
    (".config/emacs" declarative guix-home directory owned keep #t #f)
    (".config/emacs/sk-theme-generated.el"
     declarative guix-home symlink any keep #t
     (home-file ".config/emacs/sk-theme-generated.el"))
    (".config/fish" mixed application directory owned keep #t #f)
    (".config/fish/config.fish" declarative guix-home symlink any keep #t
     (home-file ".config/fish/config.fish"))
    (".config/fontconfig" declarative guix-home directory owned keep #t #f)
    (".config/fontconfig/fonts.conf" declarative guix-home symlink any keep #t
     (home-file ".config/fontconfig/fonts.conf"))
    (".config/git" declarative guix-home directory owned keep #t #f)
    (".config/git/config" declarative guix-home symlink any keep #t
     (home-file ".config/git/config"))
    (".config/glib-2.0" durable-local application directory private keep #f #f)
    (".config/gtk-3.0" declarative guix-home directory owned keep #t #f)
    (".config/gtk-3.0/settings.ini" declarative guix-home symlink any keep #t
     (home-file ".config/gtk-3.0/settings.ini"))
    (".config/gtk-4.0" declarative guix-home directory owned keep #t #f)
    (".config/gtk-4.0/settings.ini" declarative guix-home symlink any keep #t
     (home-file ".config/gtk-4.0/settings.ini"))
    (".config/guix" mixed user directory owned keep #t #f)
    (".config/guix/channels.scm" declarative repo symlink any keep #t
     (repo "guix/channels.scm"))
    (".config/guix/current" declarative guix-profile symlink any keep #t
     (prefix "/var/guix/profiles/per-user/"))
    (".config/guix/home.scm" declarative repo symlink any keep #t
     (repo "guix/home/guixpc.scm"))
    (".config/guix/machines/guixpc/todo.org"
     declarative repo symlink any keep #t
     (repo "guix/machines/guixpc/todo.org"))
    (".config/guix/systems/guixpc.scm" declarative repo symlink any keep #t
     (repo "guix/systems/guixpc.scm"))
    (".config/kitty" declarative guix-home directory owned keep #t #f)
    (".config/kitty/kitty.conf" declarative guix-home symlink any keep #t
     (home-file ".config/kitty/kitty.conf"))
    (".config/matplotlib" durable-local application directory owned keep #f #f)
    (".config/mimeapps.list" declarative guix-home symlink any keep #t
     (home-file ".config/mimeapps.list"))
    (".config/nano" durable-local application directory owned keep #f #f)
    (".config/procps" durable-local application directory private keep #f #f)
    (".config/pulse" mixed application directory private keep #t #f)
    (".config/pulse/client.conf" declarative guix-home symlink any keep #t
     (home-file ".config/pulse/client.conf"))
    (".config/ranger" declarative repo directory owned keep #t #f)
    (".config/ranger/rc.conf" declarative repo symlink any keep #t
     (repo "ranger/rc.conf"))
    (".config/ranger/rifle.conf" declarative repo symlink any keep #t
     (repo "ranger/rifle.conf"))
    (".config/ranger/scope.sh" declarative repo symlink any keep #t
     (repo "ranger/scope.sh"))
    (".config/shepherd" declarative guix-home directory owned keep #t #f)
    (".config/shepherd/init.scm" declarative guix-home symlink any keep #t
     (home-file ".config/shepherd/init.scm"))
    (".config/sk-theme" declarative guix-home directory owned keep #t #f)
    (".config/sk-theme/tokens.scm" declarative guix-home symlink any keep #t
     (home-file ".config/sk-theme/tokens.scm"))
    (".config/sk-theme/x-session.sh" declarative guix-home symlink any keep #t
     (home-file ".config/sk-theme/x-session.sh"))

    (".local/share" mixed user directory owned keep #t #f)
    (".local/state" state-log user directory owned keep #t #f)
    (".local/share/Trash" durable-local user directory private keep #f #f)
    (".local/share/applications"
     declarative guix-home directory owned keep #t #f)
    (".local/share/applications/sk-emacsclient-files.desktop"
     declarative guix-home symlink any keep #t
     (home-file ".local/share/applications/sk-emacsclient-files.desktop"))
    (".local/share/applications/sk-emacsclient-mail.desktop"
     declarative guix-home symlink any keep #t
     (home-file ".local/share/applications/sk-emacsclient-mail.desktop"))
    (".local/share/applications/sk-emacsclient-org-protocol.desktop"
     declarative guix-home symlink any keep #t
     (home-file
      ".local/share/applications/sk-emacsclient-org-protocol.desktop"))
    (".local/share/fish" durable-local application directory private keep #f #f)
    (".local/share/pki" secret application directory private keep #f #f)
    (".local/share/ranger" durable-local application directory owned keep #f #f)
    (".local/share/sk-theme" declarative guix-home directory owned keep #t #f)
    (".local/share/sk-theme/assets/wallpapers/waifu-cyberpunk.png"
     declarative guix-home symlink any keep #t
     (home-file
      ".local/share/sk-theme/assets/wallpapers/waifu-cyberpunk.png"))
    (".local/share/xorg"
     state-log application directory owned migrate-candidate #f #f)

    (".local/state/btop.log" state-log application regular owned keep #f #f)
    (".local/state/emacs" durable-local application directory owned keep #t #f)
    (".local/state/shepherd" state-log guix-home directory private keep #t #f)
    (".local/state/sk-exwm" state-log repo directory private keep #t #f)
    (".local/state/wireplumber"
     durable-local guix-home directory private keep #t #f)

    (".cache/YAPF" cache application directory owned keep #f #f)
    (".cache/chromium" cache application directory owned keep #t #f)
    (".cache/common-lisp" cache application directory owned keep #f #f)
    (".cache/emacs" mixed application directory owned review #t #f)
    (".cache/event-sound-cache.tdb.guixpc.x86_64-unknown-linux-gnu"
     cache application regular owned keep #f #f)
    (".cache/fastfetch" cache application directory owned keep #f #f)
    (".cache/fish" cache application directory private keep #f #f)
    (".cache/fontconfig" cache application directory owned keep #f #f)
    (".cache/gdm" cache application directory private keep #f #f)
    (".cache/gstreamer-1.0" cache application directory owned keep #f #f)
    (".cache/guile" cache application directory owned keep #f #f)
    (".cache/guix" cache application directory owned keep #t #f)
    (".cache/jedi" cache application directory owned keep #f #f)
    (".cache/kitty" cache application directory owned keep #f #f)
    (".cache/mesa_shader_cache" cache application directory private keep #f #f)
    (".cache/obexd" cache application directory private keep #f #f)
    (".cache/org-persist" cache application directory owned keep #f #f)
    (".cache/radv_builtin_shaders"
     cache application directory private keep #f #f)
    (".cache/ranger" cache application directory owned keep #f #f)
    (".cache/sk-exwm-startx.log"
     state-log repo regular owned migrate-candidate #f #f)))

(define %scan-roots
  '("." ".config" ".local" ".local/share" ".local/state" ".cache"))

(define home
  (let ((value (getenv "HOME")))
    (unless (and value (absolute-file-name? value))
      (error "HOME must name an absolute path"))
    (canonicalize-path value)))

(define repo
  (dirname (dirname (canonicalize-path (car (command-line))))))

(define pass-count 0)
(define review-count 0)
(define fail-count 0)
(define absent-count 0)

(define (full-path relative)
  (if (string=? relative ".")
      home
      (string-append home "/" relative)))

(define (safe-lstat path)
  (catch 'system-error
    (lambda () (lstat path))
    (lambda arguments #f)))

(define (safe-readlink path)
  (catch 'system-error
    (lambda () (readlink path))
    (lambda arguments #f)))

(define (mode-string status)
  (let* ((text (number->string (stat:perms status) 8))
         (padding (max 0 (- 4 (string-length text)))))
    (string-append (make-string padding #\0) text)))

(define (target-check policy target)
  (match policy
    (#f (list #t #f))
    (('repo relative)
     (let ((expected (string-append repo "/" relative)))
       (list (and target (string=? target expected)) expected)))
    (('prefix prefix)
     (list (and target (string-prefix? prefix target)) prefix))
    (('home-file relative)
     (let* ((source
             (string-append home "/.guix-home/files/" relative))
            (expected (safe-readlink source)))
       (list (and target expected (string=? target expected)) expected)))
    (_ (list #f policy))))

(define (permission-status policy status)
  (let ((shared-bits (logand (stat:perms status) #o077)))
    (case policy
      ((private) (if (zero? shared-bits) 'pass 'fail))
      ((review-private) (if (zero? shared-bits) 'pass 'review))
      (else 'pass))))

(define (record-status! value)
  (case value
    ((pass) (set! pass-count (+ pass-count 1)))
    ((review) (set! review-count (+ review-count 1)))
    ((fail) (set! fail-count (+ fail-count 1)))
    ((absent) (set! absent-count (+ absent-count 1)))))

(define (emit-record relative class owner expected-kind mode-policy
                     disposition required? target-policy)
  (let ((status (safe-lstat (full-path relative))))
    (if (not status)
        (let ((result (if required? 'fail 'absent)))
          (record-status! result)
          (write `((path . ,relative)
                   (class . ,class)
                   (owner . ,owner)
                   (disposition . ,disposition)
                   (status . ,result)))
          (newline))
        (let* ((kind (stat:type status))
               (target
                (and (eq? kind 'symlink)
                     (safe-readlink (full-path relative))))
               (target-result (target-check target-policy target))
               (target-ok? (car target-result))
               (expected-target (cadr target-result))
               (permissions (permission-status mode-policy status))
               (result
                (cond
                 ((not (= (stat:uid status) (getuid))) 'fail)
                 ((and (not (eq? expected-kind 'any))
                       (not (eq? kind expected-kind))) 'fail)
                 ((not target-ok?) 'fail)
                 ((eq? permissions 'fail) 'fail)
                 ((or (eq? permissions 'review)
                      (eq? class 'unknown)
                      (memq disposition
                            '(review migrate-candidate remove-candidate)))
                  'review)
                 (else 'pass))))
          (record-status! result)
          (write `((path . ,relative)
                   (class . ,class)
                   (owner . ,owner)
                   (kind . ,kind)
                   (mode . ,(mode-string status))
                   (size . ,(stat:size status))
                   (target . ,target)
                   (expected-target . ,expected-target)
                   (disposition . ,disposition)
                   (status . ,result)))
          (newline)))))

(define (known-path? relative)
  (any (lambda (entry) (string=? relative (car entry))) %entries))

(define (scan-root relative)
  (let* ((path (full-path relative))
         (status (safe-lstat path)))
    (when (and status (eq? (stat:type status) 'directory))
      (for-each
       (lambda (name)
         (let ((child
                (if (string=? relative ".")
                    name
                    (string-append relative "/" name))))
           (unless (known-path? child)
             (let* ((child-status (safe-lstat (full-path child)))
                    (kind (and child-status (stat:type child-status)))
                    (target
                     (and (eq? kind 'symlink)
                          (safe-readlink (full-path child)))))
               (record-status! 'review)
               (write `((path . ,child)
                        (class . unknown)
                        (owner . unknown)
                        (kind . ,kind)
                        (mode .
                              ,(and child-status
                                    (mode-string child-status)))
                        (size . ,(and child-status
                                     (stat:size child-status)))
                        (target . ,target)
                        (disposition . review)
                        (status . review)))
               (newline)))))
       (sort
        (filter (lambda (name)
                  (not (member name '("." ".."))))
                (scandir path))
        string<?)))))

(write `(schema ,%schema))
(newline)
(write `(home ,home))
(newline)

(for-each (lambda (entry) (apply emit-record entry)) %entries)
(for-each scan-root %scan-roots)

(let ((overall
       (cond
        ((positive? fail-count) 'fail)
        ((positive? review-count) 'review)
        (else 'pass))))
  (write `((summary . ,overall)
           (pass . ,pass-count)
           (review . ,review-count)
           (fail . ,fail-count)
           (absent . ,absent-count)))
  (newline)
  (exit (if (zero? fail-count) 0 1)))
