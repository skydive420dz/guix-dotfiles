;;; sk-example.el --- Small arithmetic project fixture -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rafael Oliveira

;; Author: Rafael Oliveira <r0liveira@icloud.com>
;; Maintainer: Rafael Oliveira <r0liveira@icloud.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: lisp, tools
;; URL: https://github.com/skydive420dz/guix-dotfiles

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;;; Commentary:

;; This dependency-free package is the tracked Emacs Lisp project used to
;; exercise project discovery, evaluation, ERT, byte compilation, Checkdoc,
;; package-lint, documentation, xref, Edebug, and macro expansion.

;;; Code:

(defun sk-example-add (left right)
  "Return LEFT plus RIGHT."
  (+ left right))

(defmacro sk-example-twice (&rest body)
  "Evaluate BODY twice and return the result of its second evaluation."
  (declare (indent 0) (debug t))
  `(progn ,@body ,@body))

(provide 'sk-example)

;;; sk-example.el ends here
