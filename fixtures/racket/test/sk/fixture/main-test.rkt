#lang racket/base

(module+ test
  (require rackunit
           sk/fixture/main)

  (check-equal? (fixture-add 20 22) 42)
  (check-equal? (fixture-double 21) 42)
  (check-equal? (fixture-answer) 42)
  (check-equal? (with-fixture-answer answer (+ answer 0)) 42))
