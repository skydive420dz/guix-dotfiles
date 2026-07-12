;;; sample.el --- Arithmetic fixture for editor checks -*- lexical-binding: t; -*-

;;; Commentary:

;; Small, dependency-free source used by ERT, byte compilation, and Checkdoc.

;;; Code:

(defun sk-fixture-add (left right)
  "Return LEFT plus RIGHT."
  (+ left right))

(message "sum: %s" (sk-fixture-add 20 22))

(provide 'sample)

;;; sample.el ends here
