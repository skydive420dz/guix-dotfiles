;;; math.scm --- Small Guile project workflow fixture

;;; Commentary:

;; This dependency-free module exercises project-aware compilation, testing,
;; documentation, completion, evaluation, and definition navigation.

;;; Code:

(define-module (sk fixture math)
  #:export (fixture-add
            fixture-double
            fixture-answer))

(define (fixture-add left right)
  "Return LEFT plus RIGHT."
  (+ left right))

(define (fixture-double value)
  "Return twice VALUE."
  (fixture-add value value))

(define (fixture-answer)
  "Return the fixture answer."
  (fixture-double 21))

;;; math.scm ends here
