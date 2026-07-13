;;; backend-check.el --- Isolated connected Lisp backend checks -*- lexical-binding: t; -*-

;;; Commentary:

;; This file runs in its own batch Emacs process under an isolated HOME and
;; XDG tree.  It starts only disposable Guile/Geiser and SBCL/SLY backends,
;; drives every backend request asynchronously, and tears down only processes
;; created after this checker started.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst sk/backend-source-root
  (file-name-as-directory
   (file-truename
    (or (getenv "SK_EMACS_CHECK_SOURCE_ROOT")
        (error "SK_EMACS_CHECK_SOURCE_ROOT is required"))))
  "Copied source tree used by the connected backend checks.")

(defconst sk/backend-sandbox-root
  (file-name-as-directory
   (file-truename
    (or (getenv "SK_EMACS_CHECK_SANDBOX_ROOT")
        (error "SK_EMACS_CHECK_SANDBOX_ROOT is required"))))
  "Only state root available to the connected backend checks.")

(defconst sk/backend-initial-processes (process-list)
  "Processes that predate this disposable checker.")

(defconst sk/backend-initial-buffers (buffer-list)
  "Buffers that predate this disposable checker.")

(defun sk/backend-assert (condition format-string &rest arguments)
  "Signal an error unless CONDITION holds.
FORMAT-STRING and ARGUMENTS describe the failed backend assertion."
  (unless condition
    (error "backend-check: %s"
           (apply #'format format-string arguments))))

(defun sk/backend-wait-for (predicate description &optional timeout)
  "Wait until PREDICATE succeeds or signal an error for DESCRIPTION.
TIMEOUT defaults to twenty seconds.  Process filters and timers remain active
while this function waits."
  (let ((deadline (+ (float-time) (or timeout 20))))
    (while (and (not (funcall predicate))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (sk/backend-assert (funcall predicate)
                       "timed out waiting for %s" description)))

(defun sk/backend-created-processes ()
  "Return live Emacs process objects created by this checker."
  (cl-set-difference (process-list)
                     sk/backend-initial-processes
                     :test #'eq))

(defun sk/backend-created-buffers ()
  "Return live buffers created by this checker."
  (cl-set-difference (buffer-list)
                     sk/backend-initial-buffers
                     :test #'eq))

(defun sk/backend-cleanup ()
  "Delete only processes and buffers created by this checker."
  (dolist (process (sk/backend-created-processes))
    (when (processp process)
      (ignore-errors (set-process-query-on-exit-flag process nil))
      (when (process-live-p process)
        (ignore-errors (delete-process process)))))
  ;; Give owned sentinels a bounded chance to observe the process exits before
  ;; their buffers disappear.
  (accept-process-output nil 0.05)
  (dolist (buffer (sk/backend-created-buffers))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq-local kill-buffer-query-functions nil))
      (ignore-errors (kill-buffer buffer)))))

(defun sk/backend-geiser-request (buffer code description)
  "Send Geiser CODE asynchronously from BUFFER and return its retort.
DESCRIPTION identifies the request if its callback never arrives."
  (let (done retort)
    (with-current-buffer buffer
      (geiser-eval--send
       code
       (lambda (answer)
         (setq retort answer
               done t))))
    (sk/backend-wait-for (lambda () done) description)
    (sk/backend-assert (geiser-eval--retort-p retort)
                       "%s returned a malformed Geiser retort: %S"
                       description retort)
    retort))

(defun sk/backend-geiser-result (retort description)
  "Return RETORT's Geiser value after checking DESCRIPTION for errors."
  (sk/backend-assert (not (geiser-eval--retort-error retort))
                     "%s failed: %S"
                     description
                     (geiser-eval--retort-error retort))
  (geiser-eval--retort-result retort))

(defun sk/backend-check-geiser ()
  "Exercise the real Guile fixture through an isolated Geiser connection."
  (require 'geiser-guile)
  (require 'geiser-eval)
  (require 'geiser-edit)
  (require 'geiser-repl)
  (let* ((project (expand-file-name "fixtures/guile/"
                                    sk/backend-source-root))
         (source-directory (expand-file-name "src/" project))
         (source-file
          (expand-file-name "sk/fixture/math.scm" source-directory))
         (module "(sk fixture math)")
         (source-buffer nil)
         (repl-buffer nil))
    (dolist (path (list project source-directory source-file))
      (sk/backend-assert (file-readable-p path)
                         "unreadable Guile fixture path: %s" path))
    (sk/backend-assert (executable-find "guile")
                       "candidate profile lacks Guile")
    (setq geiser-repl-query-on-exit-p nil
          geiser-repl-history-filename
          (expand-file-name "geiser-history" sk/backend-sandbox-root)
          geiser-guile-binary (executable-find "guile"))
    (setq source-buffer (find-file-noselect source-file))
    (with-current-buffer source-buffer
      (scheme-mode)
      (setq-local default-directory project)
      (setq-local geiser-guile-load-path (list source-directory))
      (geiser-mode 1)
      (geiser 'guile)
      (setq repl-buffer geiser-repl--repl))
    (sk/backend-assert (buffer-live-p repl-buffer)
                       "Geiser did not create a REPL buffer")
    (sk/backend-assert (process-live-p (get-buffer-process repl-buffer))
                       "Geiser Guile process is not live")

    (let ((load-retort
           (sk/backend-geiser-request
            source-buffer `(:load-file ,source-file) "Guile fixture load")))
      (sk/backend-geiser-result load-retort "Guile fixture load"))

    (let* ((retort
            (sk/backend-geiser-request
             source-buffer
             `(:eval (:scm "(fixture-answer)") ,module)
             "Guile evaluation"))
           (value (sk/backend-geiser-result retort "Guile evaluation")))
      (sk/backend-assert (equal value 42)
                         "Guile evaluation returned %S instead of 42" value))

    (let* ((retort
            (sk/backend-geiser-request
             source-buffer
             `(:eval (:ge completions "fixture-") ,module)
             "Guile semantic completion"))
           (completions
            (sk/backend-geiser-result retort "Guile semantic completion")))
      (sk/backend-assert (member "fixture-add" completions)
                         "Guile completion omitted fixture-add: %S"
                         completions))

    (let* ((retort
            (sk/backend-geiser-request
             source-buffer
             `(:eval (:ge symbol-documentation 'fixture-add) ,module)
             "Guile documentation"))
           (documentation
            (sk/backend-geiser-result retort "Guile documentation"))
           (docstring (cdr (assoc "docstring" documentation))))
      (sk/backend-assert
       (and (stringp docstring)
            (string-match-p "Return LEFT plus RIGHT" docstring))
       "Guile documentation did not contain the fixture docstring: %S"
       documentation))

    (let* ((retort
            (sk/backend-geiser-request
             source-buffer
             `(:eval (:ge symbol-location 'fixture-add) ,module)
             "Guile definition location"))
           (location
            (sk/backend-geiser-result retort "Guile definition location"))
           (location-file (geiser-edit--location-file location)))
      (sk/backend-assert
       (and location-file
            (file-equal-p source-file location-file))
       "Guile definition resolved outside the fixture: %S" location)
      (with-current-buffer source-buffer
        (sk/backend-assert
         (geiser-edit--try-edit "fixture-add" location nil t)
         "Geiser could not navigate to fixture-add")))

    (let* ((marker "SK-BACKEND-SYNTHETIC")
           (failure
            (sk/backend-geiser-request
             source-buffer
             `(:eval (:scm ,(format "(error %S)" marker)) ,module)
             "Guile controlled failure"))
           (failure-data (geiser-eval--retort-error failure))
           (failure-output (geiser-eval--retort-output failure))
           (failure-message
            (and failure-data
                 (geiser-eval--error-msg failure-data))))
      (sk/backend-assert failure-data
                         "Guile controlled failure unexpectedly succeeded")
      (sk/backend-assert
       (cl-some
        (lambda (text)
          (and (stringp text)
               (string-match-p (regexp-quote marker) text)))
        (list failure-message failure-output))
       "Guile failure output lost its condition: error=%S output=%S"
       failure-data failure-output))

    (let* ((retort
            (sk/backend-geiser-request
             source-buffer
             `(:eval (:scm "(fixture-answer)") ,module)
             "Guile post-failure recovery"))
           (value
            (sk/backend-geiser-result retort "Guile post-failure recovery")))
      (sk/backend-assert (equal value 42)
                         "Guile did not recover after failure: %S" value))
    (princ "backend-check: Geiser/Guile PASS\n")))

(defun sk/backend-sly-request (connection form description &optional package)
  "Send SLY FORM asynchronously through CONNECTION and return its value.
DESCRIPTION identifies the request if its callback never arrives.  PACKAGE
defaults to COMMON-LISP-USER."
  (let (done value)
    (with-current-buffer (process-buffer connection)
      (let ((sly-buffer-connection connection))
        (sly-eval-async
            form
          (lambda (answer)
            (setq value answer
                  done t))
          (or package "COMMON-LISP-USER"))))
    (sk/backend-wait-for
     (lambda ()
       (or done
           (not (process-live-p connection))
           (and (fboundp 'sly-db-buffers)
                (car (sly-db-buffers connection)))))
     description)
    (cond
     (done value)
     ((not (process-live-p connection))
      (error "backend-check: SLY connection died during %s" description))
     (t
      (let ((debugger (car (sly-db-buffers connection))))
        (error "backend-check: %s entered debugger: %S"
               description
               (and (buffer-live-p debugger)
                    (with-current-buffer debugger sly-db-condition))))))))

(defun sk/backend-check-sly ()
  "Exercise the real ASDF fixture through an isolated SLY connection."
  (require 'sly)
  (sly-setup)
  (let* ((project (expand-file-name "fixtures/common-lisp/"
                                    sk/backend-source-root))
         (asd-file (expand-file-name "sk-fixture.asd" project))
         (source-file (expand-file-name "src/core.lisp" project))
         (asdf-cache (expand-file-name "asdf/" sk/backend-sandbox-root))
         (program (executable-find "sbcl"))
         (connected nil)
         (connection nil)
         (inferior-buffer nil)
         (sly-kill-without-query-p t)
         (sly-db-focus-debugger 'never))
    (dolist (path (list project asd-file source-file))
      (sk/backend-assert (file-readable-p path)
                         "unreadable Common Lisp fixture path: %s" path))
    (sk/backend-assert program "candidate profile lacks SBCL")
    (sk/backend-assert (not (sly-connected-p))
                       "disposable checker inherited a SLY connection")
    (make-directory asdf-cache t)
    (setq inferior-buffer
          (sly-start
           :program program
           :directory project
           :buffer "*sk-backend-check-sbcl*"
           :name 'sk-backend-check
           :env
           (list
            (format
             "CL_SOURCE_REGISTRY=(:source-registry (:directory %S) :ignore-inherited-configuration)"
             project)
            (format
             "ASDF_OUTPUT_TRANSLATIONS=(:output-translations (t (%S :implementation)) :ignore-inherited-configuration)"
             asdf-cache))
           :init-function
           (lambda ()
             (setq connection (sly-current-connection)
                   connected t))))
    (sk/backend-assert (buffer-live-p inferior-buffer)
                       "SLY did not create an inferior SBCL buffer")
    (sk/backend-wait-for (lambda () connected) "SLY connection" 45)
    (sk/backend-assert (and (processp connection)
                            (process-live-p connection))
                       "SLY connection is not live")

    (let* ((form
            (format
             (concat "(progn (require :asdf) "
                     "(asdf:load-asd #P%S) "
                     "(asdf:test-system \"sk-fixture\") "
                     "(if (= (uiop:symbol-call :sk-fixture :add 20 22) 42) "
                     ":sk-backend-ok "
                     "(error \"SK-FIXTURE-RESULT\")))")
             asd-file))
           (result
            (sk/backend-sly-request
             connection
             `(slynk:eval-and-grab-output ,form)
             "ASDF load and test-op"))
           (output (car result))
           (value (cadr result)))
      (sk/backend-assert (equal value ":SK-BACKEND-OK")
                         "SLY evaluation returned unexpected marker %S" value)
      (sk/backend-assert
       (and (stringp output)
            (string-match-p "sk-fixture/tests: PASS" output))
       "SLY test-op output omitted its pass marker: %S" output))

    (let* ((package "COMMON-LISP-USER")
           (form
            (list 'slynk-completion:simple-completions
                  "SK-FIXTURE:A"
                  (list 'quote package)))
           (result
            (sk/backend-sly-request
             connection form "SLY semantic completion" package))
           (completions (car result)))
      (sk/backend-assert
       (cl-some
        (lambda (candidate)
          (and (stringp candidate)
               (string-equal (upcase candidate) "SK-FIXTURE:ADD")))
        completions)
       "SLY completion omitted SK-FIXTURE:ADD: %S"
       completions))

    (let ((documentation
           (sk/backend-sly-request
            connection
            '(slynk:describe-symbol "SK-FIXTURE:ADD")
            "SLY documentation")))
      (sk/backend-assert
       (and (stringp documentation)
            (string-match-p "sum of LEFT and RIGHT" documentation))
       "SLY documentation did not contain the fixture docstring: %S"
       documentation))

    (let* ((definitions
            (sk/backend-sly-request
             connection
             '(slynk:find-definitions-for-emacs "SK-FIXTURE:ADD")
             "SLY definition lookup"))
           (location (and definitions
                          (sly-xref.location (car definitions)))))
      (sk/backend-assert
       (and location
            (string-match-p (regexp-quote source-file)
                            (prin1-to-string definitions)))
       "SLY definition lookup did not resolve to core.lisp: %S"
       definitions)
      (let ((origin (current-buffer)))
        (unwind-protect
            (progn
              (sly--pop-to-source-location location nil)
              (sk/backend-assert
               (and buffer-file-name
                    (file-equal-p buffer-file-name source-file))
               "SLY definition navigation opened %S" buffer-file-name))
          (set-buffer origin))))

    (let* ((xref
            (sk/backend-sly-request
             connection
             '(slynk:xref :calls "SK-FIXTURE:ADD")
             "SLY who-calls xref")))
      ;; `sk/lisp-references' dispatches to `sly-who-calls', whose exact
      ;; compiler-supported relation is :calls.  Do not accept a portable but
      ;; different :callers result as evidence for that command.
      (sk/backend-assert
       (string-match-p "TWICE" (upcase (prin1-to-string xref)))
       "SLY who-calls xref omitted SK-FIXTURE:TWICE: %S" xref))

    ;; An asynchronous request has no `sly-eval' stack tag, so SLY displays the
    ;; debugger without entering a recursive edit.  Abort only this connection's
    ;; debugger and require a subsequent request to succeed.
    (with-current-buffer (process-buffer connection)
      (let ((sly-buffer-connection connection))
        (sly-eval-async '(cl:error "SK-BACKEND-SYNTHETIC")
                        nil
                        "COMMON-LISP-USER")))
    (sk/backend-wait-for
     (lambda () (car (sly-db-buffers connection)))
     "SLY controlled debugger" 20)
    (let ((debugger (car (sly-db-buffers connection))))
      (with-current-buffer debugger
        (sk/backend-assert
         (string-match-p "SK-BACKEND-SYNTHETIC"
                         (prin1-to-string sly-db-condition))
         "SLY debugger lost its condition: %S" sly-db-condition)
        (sly-db-abort)))
    (sk/backend-wait-for
     (lambda ()
       (not (cl-some
             (lambda (buffer)
               (and (buffer-live-p buffer)
                    (with-current-buffer buffer sly-db-level)))
             (sly-db-buffers connection))))
     "SLY debugger abort" 20)
    (sk/backend-assert (process-live-p connection)
                       "SLY connection died during controlled failure")

    (let* ((result
            (sk/backend-sly-request
             connection
             '(slynk:eval-and-grab-output
               "(if (= (sk-fixture:add 20 22) 42) :sk-backend-ok (error \"SK-FIXTURE-RECOVERY\"))")
             "SLY post-failure recovery"))
           (value (cadr result)))
      (sk/backend-assert (equal value ":SK-BACKEND-OK")
                         "SLY did not recover after failure: %S" value))
    (princ "backend-check: SLY/SBCL PASS\n")))

(unwind-protect
    (progn
      (when (equal (getenv "SK_EMACS_CHECK_BREAK_BACKEND") "1")
        (error "deliberate connected backend negative control"))
      (sk/backend-check-geiser)
      (sk/backend-check-sly)
      (princ "backend-check: PASS\n"))
  (sk/backend-cleanup))

;;; backend-check.el ends here
