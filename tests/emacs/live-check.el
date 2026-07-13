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
       (repo-root
        (file-name-directory
         (directory-file-name (file-truename sk/user-directory))))
       (lisp-fixture-files
        (mapcar
         (lambda (relative) (expand-file-name relative repo-root))
         '("fixtures/elisp/sk-example/.projectile"
           "fixtures/elisp/sk-example/Makefile"
           "fixtures/elisp/sk-example/sk-example.el"
           "fixtures/guile/.projectile"
           "fixtures/guile/Makefile"
           "fixtures/guile/src/sk/fixture/math.scm"
           "fixtures/common-lisp/.projectile"
           "fixtures/common-lisp/Makefile"
           "fixtures/common-lisp/sk-fixture.asd")))
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
       (authored-snippets-loaded-p
        (and (boundp 'sk/authored-snippet-contract)
             (fboundp 'yas-lookup-snippet)
             (seq-every-p
              (lambda (contract)
                (pcase-let ((`(,mode ,name ,_key) contract))
                  (yas-lookup-snippet name mode t)))
              sk/authored-snippet-contract)))
       (checks
        (list
         (cons "preferred Home/System Emacs executable"
               (file-equal-p
                (expand-file-name invocation-name invocation-directory)
                preferred-emacs))
         (cons "Home-first editor process environment"
               (and
                (if home-editor-p
                    (string-prefix-p
                     (concat (directory-file-name home-bin) ":")
                     (or (getenv "PATH") ""))
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
         (cons "repository-authored snippets"
               (and (equal yas-snippet-dirs (list sk/snippets-directory))
                    (file-equal-p sk/snippets-directory
                                  (expand-file-name "snippets"
                                                    sk/user-directory))
                    authored-snippets-loaded-p))
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
         (cons "Puni package generation"
               (funcall owned-library-p "puni" "puni-[0-9]*"))
         (cons "package-lint generation"
               (funcall owned-library-p
                        "package-lint" "package-lint-[0-9]*"))
         (cons "Yasnippet package generation"
               (funcall owned-library-p "yasnippet" "yasnippet-[0-9]*"))
         (cons "Eshell highlighting package generation"
               (funcall owned-library-p
                        "eshell-syntax-highlighting"
                        "eshell-syntax-highlighting-[0-9]*"))
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
               (and (= 1 (cl-count #'sk/scheme-mode-setup scheme-mode-hook
                                    :test #'eq))
                    (= 1 (cl-count #'geiser-mode--maybe-activate
                                    scheme-mode-hook :test #'eq))))
         (cons "Common Lisp setup hook"
               (and (= 1 (cl-count #'sk/common-lisp-mode-setup lisp-mode-hook
                                    :test #'eq))
                    (= 1 (cl-count #'sly-editing-mode lisp-mode-hook
                                    :test #'eq))
                    (featurep 'sly)
                    (fboundp 'sly-common-lisp-indent-function)))
         (cons "scoped Puni hooks"
               (seq-every-p
                (lambda (hook)
                  (= 1 (cl-count #'puni-mode (symbol-value hook) :test #'eq)))
                '(emacs-lisp-mode-hook lisp-interaction-mode-hook
                  scheme-mode-hook lisp-mode-hook)))
         (cons "loaded Eshell highlighting"
               (or (not (featurep 'esh-mode))
                   (and (featurep 'eshell-syntax-highlighting)
                        (bound-and-true-p
                         eshell-syntax-highlighting-global-mode))))
         (cons "format key"
               (eq (lookup-key evil-normal-state-map (kbd "SPC c f"))
                   #'sk/format-buffer))
         (cons "Lisp REPL key"
               (eq (lookup-key evil-normal-state-map (kbd "SPC l r"))
                   #'sk/lisp-repl))
         (cons "Lisp structural key"
               (eq (lookup-key evil-normal-state-map (kbd "SPC l ]"))
                   #'puni-slurp-forward))
         (cons "Lisp project command surface"
               (and
                (seq-every-p
                 (lambda (binding)
                   (eq (lookup-key evil-normal-state-map
                                   (kbd (car binding)))
                       (cdr binding)))
                 '(("SPC l D" . sk/lisp-debug)
                   ("SPC l g" . sk/lisp-definition)
                   ("SPC l m" . sk/lisp-macroexpand)
                   ("SPC l p" . sk/lisp-project-check)
                   ("SPC l x" . sk/lisp-references)))
                (eq geiser-repl-current-project-function
                    #'sk/lisp--project-root)
                geiser-repl-per-project-p
                (equal geiser-repl-add-project-paths '("." "src"))
                (string= inferior-lisp-program "sbcl")
                (fboundp 'sk/lisp--start-common-lisp-project)
                (fboundp 'sk/window-geiser-result-buffer-p)
                (fboundp 'sk/window-geiser-debugger-buffer-p)
                (seq-every-p #'file-readable-p lisp-fixture-files)
                (not (alist-get 'lisp org-babel-load-languages))))
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
          :puni (locate-library "puni")
          :eshell-highlighting (locate-library "eshell-syntax-highlighting")
          :snippets sk/snippets-directory
          :projectile (locate-library "projectile")
          :lsp (locate-library "lsp-mode")
          :sly (locate-library "sly"))))

;;; live-check.el ends here
