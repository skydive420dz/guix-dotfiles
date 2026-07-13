;;; sk-example-test.el --- Tests for sk-example -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rafael Oliveira

;; Author: Rafael Oliveira <r0liveira@icloud.com>
;; Maintainer: Rafael Oliveira <r0liveira@icloud.com>

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;;; Commentary:

;; ERT behavior checks and warning-fatal Checkdoc acceptance for the complete
;; tracked project fixture.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'checkdoc)
(require 'sk-example)

(defconst sk-example-test--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the sk-example test source.")

(defun sk-example-test--checkdoc-warnings (file)
  "Return the Checkdoc warning strings reported for FILE."
  (let (warnings)
    (cl-letf (((symbol-function 'warn)
               (lambda (format-string &rest arguments)
                 (push (apply #'format format-string arguments) warnings))))
      (checkdoc-file file))
    (nreverse warnings)))

(ert-deftest sk-example-add-test ()
  (should (= (sk-example-add 20 22) 42)))

(ert-deftest sk-example-twice-test ()
  (let ((count 0))
    (should (= (sk-example-twice
                 (setq count (1+ count)))
               2))
    (should (= count 2))))

(ert-deftest sk-example-checkdoc-clean ()
  (let ((source (expand-file-name "../sk-example.el"
                                  sk-example-test--directory))
        (test-source (expand-file-name "sk-example-test.el"
                                       sk-example-test--directory)))
    (dolist (file (list source test-source))
      (should-not (sk-example-test--checkdoc-warnings file)))))

(provide 'sk-example-test)

;;; sk-example-test.el ends here
