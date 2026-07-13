;;; sk-clojure.el --- Guix-only Clojure editing workflow -*- lexical-binding: t; -*-

;; Opening a Clojure file configures editing and static linting only.  The JVM
;; REPL and clojure-lsp are deliberately explicit, project-scoped actions.

(require 'cl-lib)
(require 'comint)
(require 'subr-x)
(require 'sk-lisp)
(require 'sk-lsp)

(declare-function clojure-backward-logical-sexp "clojure-mode")
(declare-function clojure-find-ns "clojure-mode")
(declare-function lsp-workspaces "lsp-mode")
(declare-function sk/code-definition "sk-lsp")
(declare-function sk/code-docs "sk-lsp")
(declare-function sk/code-references "sk-lsp")

(defvar company-backends)
(defvar flycheck-checker)
(defvar flycheck-checkers)
(defvar lsp-mode)
(defvar sk/user-directory)

(defconst sk/clojure-repository-directory
  (file-name-as-directory
   (file-truename (expand-file-name ".." sk/user-directory)))
  "Absolute root of the checkout that owns the Clojure wrappers.")

(defconst sk/clojure-guix-shell
  (expand-file-name "scripts/guix-lisp-shell"
                    sk/clojure-repository-directory)
  "Absolute Guix development-shell wrapper used by Clojure processes.")

(defconst sk/clojure-project-wrapper
  (expand-file-name "scripts/clojure-project"
                    sk/clojure-repository-directory)
  "Absolute project-aware Clojure action wrapper.")

(defun sk/clojure--command (action)
  "Return the Guix JVM-shell command for project ACTION."
  (list sk/clojure-guix-shell "jvm" "--"
        sk/clojure-project-wrapper action))

(defvar lsp-clojure-custom-server-command)
(setq lsp-clojure-custom-server-command (sk/clojure--command "lsp"))

;; Loading this client after lsp-mode registers Clojure without invoking its
;; download callback.  The non-nil custom command above always selects the
;; repository's Guix wrapper in `lsp-clojure--build-command'.
(use-package lsp-clojure
  :if (locate-library "lsp-clojure")
  :after lsp-mode)

(defun sk/clojure--flycheck-working-directory (_checker)
  "Return the project root used for clj-kondo configuration discovery."
  (or (sk/lisp--project-root) default-directory))

(defun sk/clojure--flycheck-p ()
  "Return non-nil when the current buffer contains JVM Clojure source."
  (or (null buffer-file-name)
      (string-equal (file-name-extension buffer-file-name) "clj")))

(defun sk/clojure--register-flycheck-checker ()
  "Register the project-local clj-kondo Flycheck checker."
  ;; `flycheck-define-checker' is an autoloaded macro.  Delay both lookup and
  ;; macro expansion until Flycheck is present so loading this module remains
  ;; safe across the pre-reconfigure profile transition.
  (eval
   '(flycheck-define-checker sk-clojure-clj-kondo
      "Lint JVM Clojure from stdin using the project clj-kondo config."
      :command ("clj-kondo" "--repro" "--cache" "false"
                "--lint" "-" "--filename"
                (eval (or buffer-file-name "buffer.clj")))
      :standard-input t
      :working-directory sk/clojure--flycheck-working-directory
      :predicate sk/clojure--flycheck-p
      :error-patterns
      ((error line-start (or "<stdin>" (file-name)) ":" line ":" column
              ": error: " (message) line-end)
       (warning line-start (or "<stdin>" (file-name)) ":" line ":" column
                ": warning: " (message) line-end)
       (info line-start (or "<stdin>" (file-name)) ":" line ":" column
             ": info: " (message) line-end))
      :modes (clojure-mode))))

(with-eval-after-load 'flycheck
  (sk/clojure--register-flycheck-checker)
  (add-to-list 'flycheck-checkers 'sk-clojure-clj-kondo))

(defun sk/clojure-mode-setup ()
  "Configure a Clojure source buffer without starting a JVM or LSP."
  (eldoc-mode 1)
  (when (fboundp 'company-mode)
    (company-mode 1)
    (setq-local company-backends
                '((company-capf company-yasnippet)
                  company-files
                  company-keywords
                  company-dabbrev-code)))
  (when (and (fboundp 'flycheck-mode)
             (sk/clojure--flycheck-p))
    (setq-local flycheck-checker 'sk-clojure-clj-kondo)
    (flycheck-mode 1)))

(use-package clojure-mode
  :if (locate-library "clojure-mode")
  :demand t
  :hook (clojure-mode . sk/clojure-mode-setup))

(defvar-local sk/clojure-project-root nil
  "Canonical project root associated with a Clojure REPL buffer.")

(defconst sk/clojure-stop-timeout 10.0
  "Seconds to let the nested Guix/Clojure wrapper unwind before termination.")

(define-derived-mode sk/clojure-repl-mode comint-mode "Clojure-REPL"
  "Major mode for the project-keyed Guix Clojure REPL."
  (setq-local comint-prompt-read-only t))

(defun sk/clojure--canonical-root (&optional required)
  "Return this buffer's canonical Clojure root, or signal when REQUIRED."
  (or sk/clojure-project-root
      (sk/lisp--project-root required)))

(defun sk/clojure--repl-buffer-name (root)
  "Return the unique Clojure REPL buffer name for ROOT."
  (format "*clojure-repl-%s*" (sk/lisp--project-key root)))

(defun sk/clojure--live-repl-buffer (&optional root)
  "Return the live project REPL buffer for ROOT, or nil."
  (let* ((root (or root (sk/clojure--canonical-root)))
         (buffer (and root (get-buffer (sk/clojure--repl-buffer-name root)))))
    (and buffer
         (with-current-buffer buffer
           (let ((process (get-buffer-process buffer)))
             (and (processp process)
                  (process-live-p process)
                  (equal root (process-get process 'sk/clojure-project-root))
                  buffer))))))

(defun sk/clojure--assert-wrapper (path label)
  "Require executable wrapper PATH, identifying it as LABEL."
  (unless (file-executable-p path)
    (user-error "Clojure %s is not executable: %s" label path)))

(defun sk/clojure-repl ()
  "Start or switch to the Guix Clojure REPL for the current project."
  (interactive)
  (let* ((root (sk/clojure--canonical-root t))
         (existing (sk/clojure--live-repl-buffer root)))
    (if existing
        (pop-to-buffer existing)
      (sk/clojure--assert-wrapper sk/clojure-guix-shell "shell wrapper")
      (sk/clojure--assert-wrapper sk/clojure-project-wrapper
                                  "project wrapper")
      (let* ((default-directory root)
             (name (sk/clojure--repl-buffer-name root))
             (buffer (get-buffer-create name))
             (arguments (cdr (sk/clojure--command "repl"))))
        (apply #'make-comint-in-buffer name buffer sk/clojure-guix-shell
               nil arguments)
        (with-current-buffer buffer
          (sk/clojure-repl-mode)
          (setq-local sk/clojure-project-root root)
          (let ((process (get-buffer-process buffer)))
            (unless (processp process)
              (error "Clojure REPL started without a process"))
            (process-put process 'sk/clojure-project-root root)))
        (pop-to-buffer buffer)))))

(defun sk/clojure--require-repl ()
  "Return the current project's live REPL buffer or signal a user error."
  (or (sk/clojure--live-repl-buffer)
      (user-error "No project Clojure REPL is active; run SPC l r first")))

(defun sk/clojure--send-string (string)
  "Send STRING and a newline to the current project's Clojure REPL."
  (let* ((buffer (sk/clojure--require-repl))
         (process (get-buffer-process buffer)))
    (with-current-buffer buffer
      (goto-char (point-max))
      (comint-send-string process (concat string "\n")))
    buffer))

(defun sk/clojure--namespace ()
  "Return the current Clojure namespace name, or nil."
  (and (fboundp 'clojure-find-ns)
       (clojure-find-ns)))

(defun sk/clojure--eval-form (source)
  "Return a REPL expression that evaluates Clojure SOURCE in its namespace."
  (if-let ((namespace (sk/clojure--namespace)))
      (format
       (concat "(binding [*ns* (or (find-ns '%s) (create-ns '%s))] "
               "(clojure.core/refer 'clojure.core) "
               "(eval (read-string %S)))")
       namespace namespace source)
    (format "(eval (read-string %S))" source)))

(defun sk/clojure--last-sexp-string ()
  "Return the Clojure logical sexp before point as source text."
  (let ((end (point)))
    (save-excursion
      (skip-chars-backward " \t\n\r")
      (setq end (point))
      (condition-case nil
          (if (fboundp 'clojure-backward-logical-sexp)
              (clojure-backward-logical-sexp 1)
            (backward-sexp 1))
        (error (user-error "No Clojure sexp before point")))
      (buffer-substring-no-properties (point) end))))

(defun sk/clojure--defun-string ()
  "Return the Clojure top-level form around point as source text."
  (save-excursion
    (condition-case nil
        (progn
          (end-of-defun)
          (let ((end (point)))
            (beginning-of-defun)
            (buffer-substring-no-properties (point) end)))
      (error (user-error "No Clojure top-level form at point")))))

(defun sk/clojure-eval-buffer ()
  "Evaluate the entire current Clojure buffer in the project REPL."
  (interactive)
  (sk/clojure--require-repl)
  (sk/clojure--send-string
   (format "(load-string %S)"
           (buffer-substring-no-properties (point-min) (point-max)))))

(defun sk/clojure-eval-defun ()
  "Evaluate the current Clojure top-level form in the project REPL."
  (interactive)
  (sk/clojure--require-repl)
  (sk/clojure--send-string
   (sk/clojure--eval-form (sk/clojure--defun-string))))

(defun sk/clojure-eval-last-sexp ()
  "Evaluate the Clojure logical sexp before point in the project REPL."
  (interactive)
  (sk/clojure--require-repl)
  (sk/clojure--send-string
   (sk/clojure--eval-form (sk/clojure--last-sexp-string))))

(defun sk/clojure-macroexpand ()
  "Macroexpand the Clojure logical sexp before point in the project REPL."
  (interactive)
  (sk/clojure--require-repl)
  (sk/clojure--send-string
   (sk/clojure--eval-form
    (format "(macroexpand-1 (read-string %S))"
            (sk/clojure--last-sexp-string)))))

(defun sk/clojure-reload-namespace ()
  "Reload the current Clojure namespace in the project REPL."
  (interactive)
  (sk/clojure--require-repl)
  (let ((namespace (or (sk/clojure--namespace)
                       (user-error "Current Clojure buffer has no namespace"))))
    (sk/clojure--send-string (format "(require '%s :reload)" namespace))))

(defun sk/clojure-stop ()
  "Stop only the current project's Clojure REPL."
  (interactive)
  (let* ((root (sk/clojure--canonical-root t))
         (buffer (sk/clojure--live-repl-buffer root)))
    (unless buffer
      (user-error "No project Clojure REPL is active for %s" root))
    (let ((process (get-buffer-process buffer)))
      (when (process-live-p process)
        ;; Exit through the JVM first so Guix and its wrapper can reap every
        ;; descendant.  A bounded forced fallback protects Emacs from a hung
        ;; runtime without making ordinary shutdown abrupt.
        (comint-send-string process "(System/exit 0)\n")
        (let ((deadline (+ (float-time) sk/clojure-stop-timeout)))
          (while (and (process-live-p process)
                      (< (float-time) deadline))
            (accept-process-output process 0.05)))
        (when (process-live-p process)
          (delete-process process))))
    (kill-buffer buffer)
    (message "Stopped Clojure REPL for %s"
             (file-name-nondirectory (directory-file-name root)))))

(defun sk/clojure--require-lsp (operation)
  "Require an active Clojure LSP workspace for OPERATION."
  (unless (and (bound-and-true-p lsp-mode)
               (fboundp 'lsp-workspaces)
               (lsp-workspaces))
    (user-error
     "Clojure %s requires clojure-lsp; start it with SPC c l" operation)))

(defun sk/clojure-docs ()
  "Show Clojure documentation through the active clojure-lsp workspace."
  (sk/clojure--require-lsp "documentation")
  (sk/code-docs))

(defun sk/clojure-definition ()
  "Visit a Clojure definition through the active clojure-lsp workspace."
  (sk/clojure--require-lsp "definition lookup")
  (sk/code-definition))

(defun sk/clojure-references ()
  "Show Clojure references through the active clojure-lsp workspace."
  (sk/clojure--require-lsp "reference lookup")
  (sk/code-references))

(defun sk/clojure-debug ()
  "Report the deliberately unsupported Clojure debugger contract."
  (user-error
   "Clojure debugging is unsupported in the Guix-only comint workflow"))

(defun sk/clojure-project-check ()
  "Run the current Clojure project's Makefile-owned check gate."
  (interactive)
  (let* ((root (sk/clojure--canonical-root t))
         (makefile (expand-file-name "Makefile" root))
         (default-directory root))
    (unless (file-readable-p makefile)
      (user-error "Clojure project has no readable Makefile: %s" makefile))
    (sk/clojure--assert-wrapper sk/clojure-guix-shell "shell wrapper")
    (compile
     (mapconcat
      #'shell-quote-argument
      (list sk/clojure-guix-shell "jvm" "--" "make"
            "--no-print-directory" "-C" root "check")
      " "))))

(provide 'sk-clojure)

;;; sk-clojure.el ends here
