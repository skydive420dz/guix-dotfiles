(in-package #:sk-fixture)

(defun add (left right)
  "Return the sum of LEFT and RIGHT."
  (+ left right))

(defun twice (number)
  "Return NUMBER added to itself."
  (add number number))
