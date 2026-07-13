;;; live-check.el --- Read-only checks for the running Emacs -*- lexical-binding: t; -*-

;; This file is sent as one expression to emacsclient.  Keep it observational:
;; do not load files, start modes, create buffers, or alter live variables.

(let* ((home-emacs
        (expand-file-name "~/.guix-home/profile/bin/emacs"))
       (system-emacs
        "/run/current-system/profile/bin/emacs")
       (home-editor-p
        (file-executable-p home-emacs))
       (preferred-emacs
        (if home-editor-p home-emacs system-emacs))
       (home-bin
        (file-name-as-directory
         (expand-file-name "~/.guix-home/profile/bin")))
       (preferred-site-lisp
        (if home-editor-p
            (file-name-as-directory
             (expand-file-name "~/.guix-home/profile/share/emacs/site-lisp"))
          "/run/current-system/profile/share/emacs/site-lisp/"))
       (visible-profile-load-path
        (seq-find
         (lambda (entry)
           (and entry
                (or
                 (string-prefix-p
                  (expand-file-name
                   "~/.guix-home/profile/share/emacs/site-lisp")
                  (expand-file-name entry))
                 (string-prefix-p
                  "/run/current-system/profile/share/emacs/site-lisp"
                  (expand-file-name entry)))))
         load-path))
       (owned-library-p
        (lambda (library package-glob)
          (let ((live-library (locate-library library))
                (profile-package
                 (car (file-expand-wildcards
                       (expand-file-name package-glob
                                         preferred-site-lisp)))))
            (and live-library
                 profile-package
                 (file-in-directory-p
                  (file-truename live-library)
                  (file-name-as-directory
                   (file-truename profile-package)))))))
       (user-elpa-entry
        (catch 'found
          (dolist (entry load-path)
            (when (and entry
                       (string-match-p "/\\.emacs\\.d/elpa/"
                                       (expand-file-name entry)))
              (throw 'found entry)))
          nil))
       (unowned-load-path-entry
        (catch 'found
          (dolist (entry load-path)
            (when entry
              (let ((canonical (file-truename entry)))
                (unless (or (string-prefix-p "/gnu/store/" canonical)
                            (file-in-directory-p canonical sk/user-directory))
                  (throw 'found canonical)))))
          nil))
       (checks
        (list
         (cons "preferred Home/System Emacs executable"
               (file-equal-p
                (expand-file-name invocation-name invocation-directory)
                preferred-emacs))
         (cons "Home-first editor process environment"
               (and
                (if home-editor-p
                    (string-prefix-p home-bin (or (getenv "PATH") ""))
                  t)
                (string-prefix-p
                                 (concat
                                  (directory-file-name preferred-site-lisp)
                                  ":")
                                 (or (getenv "EMACSLOADPATH") ""))
                visible-profile-load-path
                (string=
                 (directory-file-name
                  (expand-file-name visible-profile-load-path))
                 (directory-file-name preferred-site-lisp))))
         (cons "server process"
               (and (boundp 'server-process)
                    (processp server-process)
                    (process-live-p server-process)))
         (cons "EXWM public runtime"
               (and (featurep 'exwm)
                    (featurep 'sk-exwm)
                    (bound-and-true-p exwm-wm-mode)
                    (fboundp 'exwm-manage-get-pid)
                    (fboundp 'sk/reload-modules)
                    (fboundp 'sk/exwm-assert-compatible)
                    (boundp 'sk/exwm-launch-intents)
                    (equal (sk/exwm-installed-version)
                           sk/exwm-reviewed-version)))
         (cons "EXWM reviewed workspaces"
               (and (= 5 (length exwm-workspace--list))
                    (seq-every-p #'frame-live-p exwm-workspace--list)
                    (eq (sk/exwm-workspace-frame 0)
                        (car exwm-workspace--list))))
         (cons "owned display policy"
               (and sk/window-display-policy-migrated
                    sk/window-xref-compatible-p
                    (seq-every-p
                     (lambda (rule)
                       (= 1 (cl-count rule display-buffer-alist :test #'eq)))
                     sk/window-owned-display-buffer-rules)
                    (not (seq-some
                          (lambda (legacy-rule)
                            (memq legacy-rule display-buffer-alist))
                          sk/window-legacy-display-buffer-rules))
                    (memq #'sk/window-configure-xref-buffer
                          xref-after-update-hook)))
         (cons "tracked core modules"
               (and (featurep 'sk-core)
                    (featurep 'sk-lisp)
                    (featurep 'sk-format)
                    (featurep 'sk-keys)
                    (featurep 'sk-org)))
         (cons "global Company frontend"
               (bound-and-true-p global-company-mode))
         (cons "global Flycheck diagnostics"
               (bound-and-true-p global-flycheck-mode))
         (cons "global Yasnippet frontend"
               (bound-and-true-p yas-global-mode))
         (cons "Org package generation"
               (funcall owned-library-p "org" "org-[0-9]*"))
         (cons "Geiser package generation"
               (funcall owned-library-p "geiser" "geiser-[0-9]*"))
         (cons "Geiser Guile package generation"
               (funcall owned-library-p "geiser-guile" "geiser-guile-[0-9]*"))
         (cons "Projectile package generation"
               (funcall owned-library-p "projectile" "projectile-[0-9]*"))
         (cons "LSP package generation"
               (funcall owned-library-p "lsp-mode" "lsp-mode-[0-9]*"))
         (cons "SLY package generation"
               (funcall owned-library-p "sly" "sly-[0-9]*"))
         (cons "Evil package generation"
               (funcall owned-library-p "evil" "evil-[0-9]*"))
         (cons "General package generation"
               (funcall owned-library-p "general" "general-[0-9]*"))
         (cons "use-package generation"
               (funcall owned-library-p "use-package" "use-package-[0-9]*"))
         (cons "C LSP hook" (memq #'lsp-deferred c-mode-hook))
         (cons "Python LSP hook" (memq #'lsp-deferred python-mode-hook))
         (cons "Lua LSP hook" (memq #'lsp-deferred lua-mode-hook))
         (cons "LSP Flycheck hook" (memq #'flycheck-mode lsp-mode-hook))
         (cons "LSP UI hook" (memq #'lsp-ui-mode lsp-mode-hook))
         (cons "LSP Which-Key hook"
               (memq #'lsp-enable-which-key-integration lsp-mode-hook))
         (cons "Shell Flycheck hook" (memq #'flycheck-mode sh-mode-hook))
         (cons "Scheme setup hook"
               (memq #'sk/scheme-mode-setup scheme-mode-hook))
         (cons "Common Lisp setup hook"
               (memq #'sk/common-lisp-mode-setup lisp-mode-hook))
         (cons "format key"
               (eq (lookup-key evil-normal-state-map (kbd "SPC c f"))
                   #'sk/format-buffer))
         (cons "Lisp REPL key"
               (eq (lookup-key evil-normal-state-map (kbd "SPC l r"))
                   #'sk/lisp-repl))
         (cons "no user ELPA load path" (not user-elpa-entry))
         (cons "owned load path" (not unowned-load-path-entry))
         (cons "no breadcrumb library" (not (locate-library "breadcrumb")))
         (cons "no breadcrumb package registration"
               (or (not (boundp 'package-alist))
                   (not (assq 'breadcrumb package-alist))))))
       (failures
        (delq nil
              (mapcar (lambda (check)
                        (unless (cdr check)
                          (car check)))
                      checks))))
  (if failures
      (error "live Emacs checks failed: %S" failures)
    (list :status 'ok
          :emacs emacs-version
          :path (getenv "PATH")
          :emacsloadpath (getenv "EMACSLOADPATH")
          :org (locate-library "org")
          :geiser (locate-library "geiser")
          :geiser-guile (locate-library "geiser-guile")
          :projectile (locate-library "projectile")
          :lsp (locate-library "lsp-mode")
          :sly (locate-library "sly"))))

;;; live-check.el ends here
