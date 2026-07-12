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
