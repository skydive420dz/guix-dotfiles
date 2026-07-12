;;; batch-check.el --- Isolated ERT checks for GuixPC Emacs -*- lexical-binding: t; -*-

;;; Commentary:

;; These checks run after a copied init has loaded under an isolated HOME and
;; isolated XDG directories.  Fixture buffers run their real major-mode hooks;
;; LSP startup is replaced only while those hooks are observed so no language
;; server can escape the batch process.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'checkdoc)
(require 'server)

(defconst sk/check-source-root
  (file-name-as-directory
   (or (getenv "SK_EMACS_CHECK_SOURCE_ROOT")
       (error "SK_EMACS_CHECK_SOURCE_ROOT is required")))
  "Copied source tree used by the isolated batch check.")

(defconst sk/check-original-repo
  (file-name-as-directory
   (or (getenv "SK_EMACS_CHECK_ORIGINAL_REPO")
       (error "SK_EMACS_CHECK_ORIGINAL_REPO is required")))
  "Read-only original checkout used for validation metadata.")

(defconst sk/check-real-home
  (file-name-as-directory
   (or (getenv "SK_EMACS_CHECK_REAL_HOME")
       (error "SK_EMACS_CHECK_REAL_HOME is required")))
  "Real user home that must not own batch state or package paths.")

(defun sk/check-fixture-path (relative)
  "Return the copied fixture path for RELATIVE."
  (expand-file-name (concat "fixtures/" relative) sk/check-source-root))

(defun sk/check-with-fixture (relative function)
  "Visit copied fixture RELATIVE in a temporary buffer and call FUNCTION."
  (let ((file (sk/check-fixture-path relative)))
    (should (file-readable-p file))
    (with-temp-buffer
      (setq buffer-file-name file)
      (insert-file-contents file)
      (set-auto-mode)
      (funcall function))))

(defun sk/check-lsp-fixture (relative expected-mode)
  "Assert RELATIVE enters EXPECTED-MODE and runs the real LSP hook."
  (let ((lsp-deferred-called nil))
    (cl-letf (((symbol-function 'lsp-deferred)
               (lambda () (setq lsp-deferred-called t))))
      (sk/check-with-fixture
       relative
       (lambda ()
         (should (eq major-mode expected-mode))
         (should-not (memq #'sk/format-buffer before-save-hook)))))
    (should lsp-deferred-called)))

(defun sk/check-call-mode-without-lsp (mode)
  "Call MODE while observing, but not starting, its deferred LSP hook."
  (cl-letf (((symbol-function 'lsp-deferred) #'ignore))
    (funcall mode)))

(defun sk/check-with-eldoc-fixture (relative function)
  "Run RELATIVE hooks, call FUNCTION, and verify they enable Eldoc."
  (let ((eldoc-calls nil)
        (original-eldoc-mode (symbol-function 'eldoc-mode)))
    (cl-letf (((symbol-function 'eldoc-mode)
               (lambda (&optional argument)
                 (push argument eldoc-calls)
                 (funcall original-eldoc-mode argument))))
      (sk/check-with-fixture relative function))
    (should (memq 1 eldoc-calls))))

(ert-deftest sk/check-isolated-runtime-state ()
  (should noninteractive)
  (should (file-in-directory-p (file-truename user-emacs-directory)
                               (file-truename (getenv "HOME"))))
  (should (file-in-directory-p (file-truename sk/cache-directory)
                               (file-truename (getenv "XDG_CACHE_HOME"))))
  (should (file-in-directory-p (file-truename sk/org-notes-root)
                               (file-truename (getenv "HOME"))))
  (should-not (bound-and-true-p recentf-mode))
  (should-not (bound-and-true-p savehist-mode))
  (should-not (bound-and-true-p save-place-mode))
  (should-not (and (boundp 'server-process)
                   (processp server-process)
                   (process-live-p server-process)))
  (dolist (file (list recentf-save-file savehist-file save-place-file))
    (should-not (file-exists-p file)))
  (should-not (file-exists-p sk/org-notes-root))
  (should-not
   (catch 'real-user-package
     (dolist (entry load-path)
       (when (and entry
                  (file-in-directory-p (expand-file-name entry)
                                       sk/check-real-home)
                  (string-match-p "/\\.emacs\\.d/elpa/" entry))
         (throw 'real-user-package entry)))
     nil))
  (should-not (locate-library "breadcrumb"))
  (should-not (and (boundp 'package-alist)
                   (assq 'breadcrumb package-alist)))
  (dolist (entry load-path)
    (when entry
      (let ((canonical (file-truename entry)))
        (should (or (string-prefix-p "/gnu/store/" canonical)
                    (string-prefix-p sk/check-sandbox-root canonical)))))))

(ert-deftest sk/check-lsp-hooks-and-shared-policy ()
  (sk/check-lsp-fixture "c/hello.c" 'c-mode)
  (sk/check-lsp-fixture "python/sample.py" 'python-mode)
  (sk/check-lsp-fixture "lua/sample.lua" 'lua-mode)
  (require 'lsp-mode)
  (should (eq lsp-completion-provider :capf))
  (should (eq lsp-diagnostics-provider :auto))
  (should (memq #'flycheck-mode lsp-mode-hook))
  (should (memq #'lsp-ui-mode lsp-mode-hook))
  (should (memq #'lsp-enable-which-key-integration lsp-mode-hook))
  (should (equal lsp-clients-clangd-executable "clangd"))
  (should (equal lsp-pylsp-server-command '("pylsp")))
  (should (equal lsp-pylsp-configuration-sources ["flake8"]))
  (should lsp-pylsp-plugins-jedi-completion-enabled)
  (should lsp-pylsp-plugins-jedi-hover-enabled)
  (should lsp-pylsp-plugins-jedi-references-enabled)
  (should lsp-pylsp-plugins-pyflakes-enabled)
  (should lsp-pylsp-plugins-flake8-enabled)
  (should (equal lsp-clients-lua-language-server-command
                 '("lua-language-server")))
  (should-not lsp-lua-telemetry-enable)
  (should (equal company-backends
                 '((company-capf company-yasnippet)
                   company-files
                   company-keywords
                   company-dabbrev-code))))

(ert-deftest sk/check-flycheck-hooks ()
  (sk/check-with-fixture
   "shell/sample.sh"
   (lambda ()
     (should (eq major-mode 'sh-mode))
     (should (bound-and-true-p flycheck-mode))
     (should (eq (flycheck-get-checker-for-buffer) 'sh-posix-bash))
     (should (equal (flycheck-get-next-checkers 'sh-posix-bash)
                    '(sh-shellcheck)))))
  (sk/check-with-fixture
   "json/sample.json"
   (lambda ()
     (should (memq major-mode '(json-mode js-json-mode)))
     (should (bound-and-true-p flycheck-mode))
     (should (eq flycheck-checker 'json-jq))))
  (sk/check-with-fixture
   "json/sample.jsonc"
   (lambda ()
     (should (eq major-mode 'jsonc-mode))
     (should-not (bound-and-true-p flycheck-mode))
     (should-not flycheck-checker))))

(ert-deftest sk/check-lisp-hooks-and-backends ()
  (sk/check-with-eldoc-fixture
   "elisp/sample.el"
   (lambda ()
     (should (eq major-mode 'emacs-lisp-mode))
     (should (eq (local-key-binding (kbd "C-c C-b")) #'eval-buffer))
     (should (eq (sk/lisp--dialect) 'elisp))))
  (sk/check-with-eldoc-fixture
   "scheme/sample.scm"
   (lambda ()
     (should (eq major-mode 'scheme-mode))
     (should (bound-and-true-p geiser-mode))
     (should (bound-and-true-p company-mode))
     (should (eq (car company-backends) 'company-capf))
     (should (equal scheme-program-name "guile"))
     (should (eq (sk/lisp--dialect) 'scheme))))
  (sk/check-with-eldoc-fixture
   "common-lisp/sample.lisp"
   (lambda ()
     (should (eq major-mode 'lisp-mode))
     (should (eq lisp-indent-function #'common-lisp-indent-function))
     (should (equal inferior-lisp-program "sbcl"))
     (should (fboundp 'sly))
     (should-not (bound-and-true-p sly-mode))
     (should (eq (sk/lisp--dialect) 'common-lisp))))
  (dolist (extension '("cl" "asd"))
    (sk/check-with-eldoc-fixture
     (concat "common-lisp/sample." extension)
     (lambda () (should (eq major-mode 'lisp-mode))))))

(ert-deftest sk/check-org-hooks-without-personal-notes ()
  (sk/check-with-fixture
   "org/sample.org"
   (lambda ()
     (should (eq major-mode 'org-mode))
     (should (bound-and-true-p visual-line-mode))
     (should (bound-and-true-p org-bullets-mode))
     (should (bound-and-true-p visual-fill-column-mode))))
  (should-not (file-exists-p sk/org-notes-root)))

(ert-deftest sk/check-key-surface ()
  (dolist (binding '(("SPC c f" . sk/format-buffer)
                     ("SPC ," . counsel-switch-buffer)
                     ("SPC b b" . counsel-ibuffer)
                     ("SPC l r" . sk/lisp-repl)
                     ("SPC l b" . sk/lisp-eval-buffer)
                     ("SPC l d" . sk/lisp-eval-defun)
                     ("SPC l e" . sk/lisp-eval-last-sexp)
                     ("SPC l k" . sk/lisp-docs)))
    (should (eq (lookup-key evil-normal-state-map (kbd (car binding)))
                (cdr binding)))))

(ert-deftest sk/check-code-action-delegates-interactively ()
  (with-temp-buffer
    (setq-local lsp-mode t)
    (let (received-action)
      (cl-letf (((symbol-function 'lsp-execute-code-action)
                 (lambda (action)
                   (interactive (list 'fixture-action))
                   (setq received-action action))))
        (sk/code-action))
      (should (eq received-action 'fixture-action)))))

(ert-deftest sk/check-diagnostics-dispatch ()
  (with-temp-buffer
    (setq-local lsp-mode t)
    (setq-local flycheck-mode t)
    (let (backend)
      (cl-letf (((symbol-function 'lsp-treemacs-errors-list)
                 (lambda () (setq backend 'lsp)))
                ((symbol-function 'flycheck-buffer)
                 (lambda () (setq backend 'flycheck-buffer)))
                ((symbol-function 'flycheck-list-errors)
                 (lambda () (setq backend 'flycheck-list))))
        (sk/code-diagnostics))
      (should (eq backend 'lsp))))
  (with-temp-buffer
    (setq-local lsp-mode nil)
    (setq-local flycheck-mode t)
    (let (calls)
      (cl-letf (((symbol-function 'flycheck-buffer)
                 (lambda () (push 'buffer calls)))
                ((symbol-function 'flycheck-list-errors)
                 (lambda () (push 'list calls))))
        (sk/code-diagnostics))
      (should (equal (reverse calls) '(buffer list)))))
  (with-temp-buffer
    (setq-local lsp-mode nil)
    (setq-local flycheck-mode nil)
    (should-error (sk/code-diagnostics) :type 'user-error)))

(ert-deftest sk/check-formatters ()
  (with-temp-buffer
    (insert "int main(){return 0;}\n")
    (sk/check-call-mode-without-lsp #'c-mode)
    (sk/format-buffer)
    (should (string-match-p "int main()" (buffer-string))))
  (with-temp-buffer
    (insert "if true; then\necho ok\nfi\n")
    (sh-mode)
    (sk/format-buffer)
    (should (string-match-p "  echo ok" (buffer-string))))
  (with-temp-buffer
    (insert "{\"b\":1,\"a\":[2,3]}\n")
    (if (fboundp 'json-mode) (json-mode) (js-json-mode))
    (sk/format-buffer)
    (should (string-match-p "\n  \"b\"" (buffer-string))))
  (sk/check-with-fixture
   "json/sample.jsonc"
   (lambda ()
     (should (eq major-mode 'jsonc-mode))
     (sk/format-buffer)
     (should (string-match-p "// JSONC keeps comments" (buffer-string)))
     (should (string-match-p "3[ \t\n\r]*],[ \t\n\r]*}" (buffer-string)))))
  (with-temp-buffer
    (insert "def add(left,right):\n    return left+right\n")
    (sk/check-call-mode-without-lsp #'python-mode)
    (sk/format-buffer)
    (should (string-match-p "def add(left, right):" (buffer-string))))
  (with-temp-buffer
    (insert "local function add(left, right)\nreturn left + right\nend\n")
    (sk/check-call-mode-without-lsp #'lua-mode)
    (sk/format-buffer)
    (should (string-match-p "\n  return left" (buffer-string))))
  (with-temp-buffer
    (insert "(progn\n(message \"x\"))\n")
    (emacs-lisp-mode)
    (sk/format-buffer)
    (should (string-match-p "  (message" (buffer-string)))))

(ert-deftest sk/check-formatter-dispatch-contract ()
  (dolist (case `((c-mode . ("clang-format"
                             ,(concat "--assume-filename="
                                      (expand-file-name "buffer.c"))))
                  (sh-mode . ("shfmt" "--filename"
                              ,(expand-file-name "buffer.sh") "-i" "2"))
                  (json-mode . ("jq" "."))
                  (js-json-mode . ("jq" "."))
                  (jsonc-mode . ("clang-format"
                                 ,(concat "--assume-filename="
                                          (expand-file-name "buffer.json"))))
                  (python-mode . ("ruff" "format" "--stdin-filename"
                                      ,(expand-file-name "buffer.py") "-"))))
    (with-temp-buffer
      (let (route)
        (cl-letf (((symbol-function 'lsp-deferred) #'ignore)
                  ((symbol-function 'sk/format--external)
                   (lambda (&rest arguments) (setq route arguments)))
                  ((symbol-function 'sk/format--indent-buffer)
                   (lambda () (setq route 'indent))))
          (funcall (car case))
          (sk/format-buffer))
        (should (equal route (cdr case))))))
  (dolist (mode '(lua-mode emacs-lisp-mode scheme-mode lisp-mode org-mode))
    (with-temp-buffer
      (let (route)
        (cl-letf (((symbol-function 'lsp-deferred) #'ignore)
                  ((symbol-function 'sk/format--external)
                   (lambda (&rest arguments) (setq route arguments)))
                  ((symbol-function 'sk/format--indent-buffer)
                   (lambda () (setq route 'indent))))
          (funcall mode)
          (sk/format-buffer))
        (should (eq route 'indent)))))
  (with-temp-buffer
    (fundamental-mode)
    (should-error (sk/format-buffer) :type 'user-error)))

(ert-deftest sk/check-formatter-visited-filenames-and-config ()
  (dolist (case '(("formatter-config/sample.c" . c)
                  ("shell/sample.sh" . shell)
                  ("python/sample.py" . python)
                  ("json/sample.jsonc" . jsonc)))
    (sk/check-with-fixture
     (car case)
     (lambda ()
       (let* ((source (expand-file-name buffer-file-name))
              (expected
               (pcase (cdr case)
                 ('c `("clang-format"
                       ,(concat "--assume-filename=" source)))
                 ('shell `("shfmt" "--filename" ,source "-i" "2"))
                 ('python `("ruff" "format" "--stdin-filename" ,source "-"))
                 ('jsonc `("clang-format"
                           ,(concat "--assume-filename="
                                    (concat (file-name-sans-extension source)
                                            ".json"))))))
              route)
         (cl-letf (((symbol-function 'sk/format--external)
                    (lambda (&rest arguments) (setq route arguments))))
           (sk/format-buffer))
         (should (equal route expected))))))
  ;; The visited filename must let clang-format find the fixture-local style.
  (sk/check-with-fixture
   "formatter-config/sample.c"
   (lambda ()
     (sk/format-buffer)
     (should (string-match-p "\n      if (1)" (buffer-string)))
     (should (string-match-p "\n            return 0;" (buffer-string))))))

(ert-deftest sk/check-lockfile-and-project-collection-policy ()
  (should create-lockfiles)
  (should (equal sk/projects-directory
                 (file-name-as-directory
                  (expand-file-name "Projects" (getenv "HOME")))))
  (should (equal projectile-project-search-path
                 `((,sk/projects-directory . 1))))
  (dolist (name '("alpha" "beta"))
    (make-directory
     (expand-file-name ".git" (expand-file-name name sk/projects-directory))
     t))
  (let ((projectile-known-projects nil)
        discovered)
    (cl-letf (((symbol-function 'projectile-add-known-project)
               (lambda (project) (push project discovered))))
      (projectile-discover-projects-in-search-path))
    (dolist (name '("alpha" "beta"))
      (let ((expected
             (directory-file-name
              (file-truename (expand-file-name name sk/projects-directory)))))
        (should
         (seq-some
          (lambda (project)
            (string= expected
                     (directory-file-name (file-truename project))))
          discovered))))))

(ert-deftest sk/check-elisp-test-foundation ()
  (let* ((fixture (sk/check-fixture-path "elisp/sample.el"))
         (compiled (byte-compile-dest-file fixture))
         (warnings-before (length sk/check-warning-records)))
    (should (byte-compile-file fixture))
    (should (file-exists-p compiled))
    (checkdoc-file fixture)
    (should (= warnings-before (length sk/check-warning-records)))
    (load fixture nil 'nomessage)
    (should (= (sk-fixture-add 20 22) 42))))

(ert-deftest sk/check-display-policy-preserves-foreign-rules ()
  (let* ((foreign-rule '("\\*Package-owned\\*" display-buffer-pop-up-window))
         (display-buffer-alist
          (append sk/window-owned-display-buffer-rules (list foreign-rule)))
         (sk/window-owned-display-buffer-rules
          sk/window-owned-display-buffer-rules)
         (policy (expand-file-name "emacs/lisp/sk-window-policy.el"
                                   sk/check-source-root)))
    (load policy nil 'nomessage)
    (load policy nil 'nomessage)
    (should (= 1 (cl-count foreign-rule display-buffer-alist :test #'eq)))
    (should (= (length sk/window-owned-display-buffer-rules)
               (cl-count-if
                (lambda (rule)
                  (memq rule sk/window-owned-display-buffer-rules))
                display-buffer-alist)))
    (should (= (length display-buffer-alist)
               (1+ (length sk/window-owned-display-buffer-rules))))
    (should (equal (last display-buffer-alist) (list foreign-rule))))
  (let* ((legacy-rule (car sk/window-legacy-display-buffer-rules))
         (collision-rule
          (list (car legacy-rule) 'display-buffer-same-window))
         (display-buffer-alist (list legacy-rule collision-rule))
         (sk/window-owned-display-buffer-rules nil)
         (sk/window-display-policy-migrated nil))
    (sk/window-install-display-buffer-rules sk/window-display-buffer-rules)
    (should-not (memq legacy-rule display-buffer-alist))
    (should (memq collision-rule display-buffer-alist))))

(defun sk/check-write-reload-module (directory name contents)
  "Write test module NAME with CONTENTS below DIRECTORY."
  (let ((file (expand-file-name (concat name ".el") directory)))
    (with-temp-file file
      (insert contents))
    file))

(defvar sk/check-reload-marker nil
  "Dynamically bound marker used by isolated reload failure tests.")

(ert-deftest sk/check-reload-preflight-and-partial-failure-reporting ()
  (let* ((directory (make-temp-file "sk-reload-modules." t))
         (sk/lisp-directory (file-name-as-directory directory))
         (foreign-rule '("\\*Reload sentinel\\*" display-buffer-same-window))
         (display-buffer-alist (list foreign-rule))
         (sk/window-owned-display-buffer-rules nil)
         (current-rules-before (copy-sequence sk/window-display-buffer-rules))
         (sk/check-reload-marker nil))
    (unwind-protect
        (progn
          (sk/check-write-reload-module
           directory "good"
           "; valid Lisp comment with unmatched (\n(setq sk/check-reload-marker '(good)\n      sk/window-display-buffer-rules '((mutated)))\n")
          (sk/check-write-reload-module directory "syntax-broken" "(setq broken\n")
          (let* ((failure (should-error
                           (sk/reload-modules
                            "Test syntax" '("good" "syntax-broken"))))
                 (message (error-message-string failure)))
            (should-not sk/check-reload-marker)
            (should (string-match-p "syntax-broken after 0/2 modules" message))
            (should (equal display-buffer-alist (list foreign-rule))))
          (sk/check-write-reload-module
           directory "runtime-broken" "(error \"deliberate runtime failure\")\n")
          (let* ((failure (should-error
                           (sk/reload-modules
                            "Test runtime" '("good" "runtime-broken"))))
                 (message (error-message-string failure)))
            (should (equal sk/check-reload-marker '(good)))
            (should (string-match-p "runtime-broken after 1/2 modules" message))
            (should (string-match-p "earlier definitions may have changed" message))
            (should (equal display-buffer-alist (list foreign-rule)))
            (should (equal sk/window-display-buffer-rules
                           current-rules-before))))
      (delete-directory directory t))))

(ert-deftest sk/check-xref-navigation-uses-public-jump ()
  (require 'xref)
  (let ((source (get-buffer-create "sk-xref-source-fixture"))
        xref-buffer)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (with-current-buffer source
            (erase-buffer)
            (insert "fixture target\n"))
          (switch-to-buffer source)
          (let* ((main-window (selected-window))
                 (item (xref-make
                        "fixture target"
                        (xref-make-buffer-location source 2)))
                 (xref-auto-jump-to-first-xref nil))
            (setq xref-buffer
                  (xref-show-xrefs (lambda () (list item)) nil))
            (should (buffer-live-p xref-buffer))
            (with-current-buffer xref-buffer
              (should sk/window-xref-navigation-mode))
            (let ((xref-window (get-buffer-window xref-buffer)))
              (should (window-live-p xref-window))
              (select-window xref-window)
              (with-current-buffer xref-buffer
                (let ((position (point-min)))
                  (while (and (< position (point-max))
                              (not (get-text-property position 'xref-item)))
                    (setq position
                          (next-single-property-change
                           position 'xref-item nil (point-max))))
                  (should (< position (point-max)))
                  (goto-char position)))
              (should (eq (key-binding (kbd "RET"))
                          #'sk/window-xref-goto-xref))
              (call-interactively (key-binding (kbd "RET")))
              (should (eq (selected-window) main-window))
              (should (eq (current-buffer) source))
              (should (= (point) 2)))))
      (when (buffer-live-p xref-buffer)
        (kill-buffer xref-buffer))
      (kill-buffer source))))

(ert-deftest sk/check-exwm-reviewed-client-contracts ()
  (require 'sk-exwm)
  (should (equal (sk/exwm-installed-version) sk/exwm-reviewed-version))
  (should (fboundp 'exwm-manage-get-pid))
  (should (fboundp 'exwm-workspace-move-window))
  (should-not (string-match-p
               "exwm--buffer->id"
               (with-temp-buffer
                 (insert-file-contents
                  (expand-file-name "emacs/lisp/sk-exwm.el"
                                    sk/check-source-root))
                 (buffer-string)))))

(ert-deftest sk/check-exwm-terminal-entry-validates-payload-first ()
  (require 'sk-exwm)
  (let ((desktop-file (make-temp-file "sk-missing-terminal." nil ".desktop"))
        (sk/exwm-launch-intents nil)
        (windows-before (length (window-list))))
    (unwind-protect
        (progn
          (with-temp-file desktop-file
            (insert "[Desktop Entry]\n"
                    "Name=Missing Terminal Fixture\n"
                    "Exec=sk-command-that-does-not-exist --flag\n"
                    "Terminal=true\n"))
          (cl-letf (((symbol-function 'counsel-linux-apps-list-desktop-files)
                     (lambda () (list (cons "missing.desktop" desktop-file)))))
            (should-error (sk/exwm-desktop-launch-spec "missing.desktop")))
          (should-not sk/exwm-launch-intents)
          (should (= windows-before (length (window-list)))))
      (delete-file desktop-file))))

(ert-deftest sk/check-exwm-rejects-hidden-and-complex-entries ()
  (require 'sk-exwm)
  (dolist (fixture
           '(("hidden.desktop"
              "[Desktop Entry]\nName=Hidden\nExec=picom\nNoDisplay=true\n")
             ("complex.desktop"
              "[Desktop Entry]\nName=Complex\nExec=sh -c \"echo \\\"$DISPLAY\\\"\" sh %F\n")))
    (let ((desktop-file (make-temp-file "sk-desktop-entry." nil ".desktop")))
      (unwind-protect
          (progn
            (with-temp-file desktop-file
              (insert (cadr fixture)))
            (cl-letf (((symbol-function 'counsel-linux-apps-list-desktop-files)
                       (lambda () (list (cons (car fixture) desktop-file)))))
              (should-error (sk/exwm-desktop-launch-spec (car fixture)))))
        (delete-file desktop-file)))))

(ert-deftest sk/check-exwm-launch-intent-matching ()
  (require 'sk-exwm)
  (let* ((slow (list :token 1 :pid 101 :process nil :matchers '("slowapp")))
         (fast (list :token 2 :pid 202 :process nil :matchers '("fastapp")))
         (sk/exwm-launch-intents (list slow fast)))
    (should (eq fast (sk/exwm-unique-matching-intent
                      202 "FastApp" "fastapp")))
    (should (eq slow (sk/exwm-unique-matching-intent
                      101 "SlowApp" "slowapp"))))
  (let* ((first (list :token 1 :pid nil :process nil :matchers '("sameapp")))
         (second (list :token 2 :pid nil :process nil :matchers '("sameapp")))
         (sk/exwm-launch-intents (list first second)))
    (should-not (sk/exwm-unique-matching-intent
                 999 "SameApp" "sameapp")))
  (let* ((proxy (make-pipe-process :name "sk-live-proxy" :noquery t))
         (single (list :token 1 :pid 500 :process proxy
                       :matchers '("singleinstance")
                       :allow-live-name-fallback t))
         (sk/exwm-launch-intents (list single)))
    (unwind-protect
        (should (eq single (sk/exwm-unique-matching-intent
                            900 "SingleInstance" "single-instance")))
      (delete-process proxy)))
  (let* ((proxy (make-pipe-process :name "sk-direct-proxy" :noquery t))
         (ordinary (list :token 1 :pid 500 :process proxy
                         :matchers '("ordinary")))
         (sk/exwm-launch-intents (list ordinary)))
    (unwind-protect
        (should-not (sk/exwm-unique-matching-intent
                     900 "Ordinary" "ordinary"))
      (delete-process proxy)))
  (let* ((first (list :token 1 :pid 500 :process nil
                      :matchers '("singleinstance")))
         (second (list :token 2 :pid 600 :process nil
                       :matchers '("singleinstance")))
         (sk/exwm-launch-intents (list first second)))
    (should-not (sk/exwm-unique-matching-intent
                 900 "SingleInstance" "single-instance")))
  (cl-letf (((symbol-value 'xcb:Atom:_NET_WM_WINDOW_TYPE_NORMAL) 1)
            ((symbol-value 'xcb:Atom:_NET_WM_WINDOW_TYPE_DIALOG) 2))
    (cl-labels
        ((placeable-p (transient fixed floating type)
           (with-temp-buffer
             (setq-local exwm-transient-for transient
                         window-size-fixed fixed
                         exwm--floating-frame floating
                         exwm-window-type (list type))
             (not (null (sk/exwm-main-client-p))))))
      (should-not (placeable-p 42 nil nil 1))
      (should-not (placeable-p nil nil nil 2))
      (should-not (placeable-p nil t nil 1))
      (should-not (placeable-p nil nil 'floating 1))
      (should (placeable-p nil nil nil 1)))))

(ert-deftest sk/check-exwm-launch-cleanup-has-no-layout-side-effect ()
  (require 'sk-exwm)
  (let ((sk/exwm-launch-intents nil)
        (sk/exwm-launch-sequence 0)
        (exwm-manage-finish-hook nil)
        (window-count-before (length (window-list)))
        (process (make-pipe-process :name "sk-intent-test" :noquery t)))
    (unwind-protect
        (let* ((intent (sk/exwm-register-launch-intent
                        process '("fixture") (selected-frame)))
               (token (plist-get intent :token)))
          (should (memq #'sk/exwm-dispatch-managed-client
                        exwm-manage-finish-hook))
          (should (equal token (process-get process 'sk/exwm-launch-token)))
          (cl-letf (((symbol-function 'process-status)
                     (lambda (_process) 'exit))
                    ((symbol-function 'process-exit-status)
                     (lambda (_process) 7)))
            (sk/exwm-launch-process-sentinel process "failed"))
          (should-not sk/exwm-launch-intents)
          (should-not (memq #'sk/exwm-dispatch-managed-client
                            exwm-manage-finish-hook))
          (should (= window-count-before (length (window-list)))))
      (when (process-live-p process)
        (delete-process process)))))

(ert-deftest sk/check-exwm-matched-client-creates-one-stack-copy ()
  (require 'sk-exwm)
  (save-window-excursion
    (delete-other-windows)
    (let ((original (get-buffer-create "sk-exwm-original-fixture"))
          (client (get-buffer-create "sk-exwm-client-fixture")))
      (unwind-protect
          (progn
            (switch-to-buffer original)
            (switch-to-buffer client)
            (let ((target (sk/exwm-display-client-in-stack
                           client (selected-frame))))
              (should (= 2 (length (sk/window-list))))
              (should (= 1 (cl-count client (sk/window-buffer-list) :test #'eq)))
              (should (eq (window-buffer target) client))
              (should (memq original (sk/window-buffer-list)))))
        (kill-buffer original)
        (kill-buffer client)))))

(ert-deftest sk/check-exwm-start-has-single-visual-owner ()
  (require 'sk-exwm)
  (let ((exwm-update-class-hook nil)
        (exwm-update-title-hook nil)
        (exwm-wm-mode t))
    (cl-letf (((symbol-function 'sk/set-wallpaper)
               (lambda () (error "wallpaper must remain Xinit-owned")))
              ((symbol-function 'sk/start-picom)
               (lambda () (error "Picom must remain Xinit-owned")))
              ((symbol-function 'sk/exwm-bind-keys) #'ignore)
              ((symbol-function 'sk/set-keyboard-repeat) #'ignore))
      (sk/exwm-start)
      (sk/exwm-start))
    (should (= 1 (cl-count #'sk/exwm-update-title
                           exwm-update-class-hook :test #'eq)))
    (should (= 1 (cl-count #'sk/exwm-update-title
                           exwm-update-title-hook :test #'eq)))))

(ert-deftest sk/check-live-expression-is-one-form ()
  (let ((file (expand-file-name "tests/emacs/live-check.el"
                                sk/check-original-repo)))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (should (listp (read (current-buffer))))
      (should-error (read (current-buffer)) :type 'end-of-file))))

(ert-deftest sk/check-deliberate-batch-negative-control ()
  (should-not (equal (getenv "SK_EMACS_CHECK_BREAK_BATCH") "1")))

(let* ((stats (ert-run-tests-batch t))
       (unexpected (ert-stats-completed-unexpected stats)))
  (when sk/check-warning-records
    (message "unexpected batch warnings: %S"
             (reverse sk/check-warning-records)))
  (kill-emacs (if (or (> unexpected 0) sk/check-warning-records) 1 0)))

;;; batch-check.el ends here
