;;; sk-format.el --- Manual formatting contract -*- lexical-binding: t; -*-

;; Formatting is explicit: no format-on-save, no language server formatting by
;; default.  External tools are owned by Guix; this file only routes commands.

(require 'subr-x)

(declare-function sk/lisp--project-root "sk-lisp" (&optional required))
(declare-function sk/fennel-format-buffer "sk-fennel")

(defun sk/format--source-filename (fallback)
  "Return the visited source filename or FALLBACK under `default-directory'."
  (expand-file-name (or buffer-file-name fallback)))

(defun sk/format--jsonc-assumed-filename ()
  "Return a JSON filename beside the current JSONC source.

clang-format does not recognize the .jsonc extension, so retain the source
directory and basename for configuration discovery while selecting its JSON
parser explicitly through a .json suffix."
  (concat (file-name-sans-extension
           (sk/format--source-filename "buffer.jsonc"))
          ".json"))

(defun sk/format--replace-buffer (buffer)
  "Replace current buffer contents with BUFFER contents, preserving point roughly."
  (let ((line (line-number-at-pos))
        (column (current-column)))
    (erase-buffer)
    (insert-buffer-substring buffer)
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column column)))

(defun sk/format--external (program &rest args)
  "Format current buffer by piping it through PROGRAM with ARGS."
  (unless (executable-find program)
    (user-error "Formatter not found: %s" program))
  (let ((output (generate-new-buffer " *sk-format-output*"))
        (error-file (make-temp-file "sk-format-error-"))
        exit-code)
    (unwind-protect
        (progn
          (setq exit-code
                (apply #'call-process-region
                       (point-min) (point-max)
                       program nil (list output error-file) nil args))
          (if (zerop exit-code)
              (sk/format--replace-buffer output)
            (user-error "%s failed: %s"
                        program
                        (string-trim
                         (with-temp-buffer
                           (insert-file-contents error-file)
                           (buffer-string))))))
      (when (buffer-live-p output)
        (kill-buffer output))
      (when (file-exists-p error-file)
        (delete-file error-file)))))

(defun sk/format--indent-buffer ()
  "Indent the current buffer using Emacs' native indentation."
  (indent-region (point-min) (point-max)))

(defun sk/format-buffer ()
  "Format the current buffer according to the manual formatting contract."
  (interactive)
  (save-excursion
    (cond
     ((derived-mode-p 'c-mode 'c-ts-mode 'c++-mode 'c++-ts-mode)
      (sk/format--external
       "clang-format"
       (concat "--assume-filename="
               (sk/format--source-filename
                (if (derived-mode-p 'c++-mode 'c++-ts-mode)
                    "buffer.cpp"
                  "buffer.c")))))
     ((derived-mode-p 'sh-mode)
      (sk/format--external "shfmt"
                           "--filename" (sk/format--source-filename "buffer.sh")
                           "-i" "2"))
     ((derived-mode-p 'jsonc-mode)
      (sk/format--external
       "clang-format"
       (concat "--assume-filename=" (sk/format--jsonc-assumed-filename))))
     ((derived-mode-p 'json-mode 'json-ts-mode 'js-json-mode)
      (sk/format--external "jq" "."))
     ((derived-mode-p 'python-mode 'python-ts-mode)
      (sk/format--external "ruff" "format"
                           "--stdin-filename"
                           (sk/format--source-filename "buffer.py")
                           "-"))
     ((derived-mode-p 'lua-mode)
      (sk/format--indent-buffer))
     ((derived-mode-p 'clojure-mode)
      (let* ((root (sk/lisp--project-root t))
             (config (expand-file-name ".cljfmt.edn" root))
             (default-directory root))
        (unless (file-readable-p config)
          (user-error "Clojure project has no readable cljfmt config: %s"
                      config))
        (sk/format--external
         "cljfmt" "fix" "--quiet" "--config" config
         "--project-root" root "-")))
     ((derived-mode-p 'fennel-mode)
      (sk/fennel-format-buffer))
     ((derived-mode-p 'emacs-lisp-mode 'lisp-interaction-mode
                      'scheme-mode 'lisp-mode 'common-lisp-mode
                      'racket-mode
                      'org-mode)
      (sk/format--indent-buffer))
     (t
      (user-error "No formatter configured for %s" major-mode)))))

(provide 'sk-format)

;;; sk-format.el ends here
