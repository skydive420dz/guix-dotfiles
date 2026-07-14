#lang racket/base

(module+ test
  (require rackunit)

  ;; Deliberate RackUnit failure for the test negative control.
  (check-equal? 41 42))
