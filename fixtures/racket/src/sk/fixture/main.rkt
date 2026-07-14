#lang racket/base

(provide fixture-add
         fixture-answer
         fixture-double
         with-fixture-answer)

(define (fixture-add left right)
  (+ left right))

(define (fixture-double value)
  (fixture-add value value))

(define (fixture-answer)
  (fixture-double 21))

(define-syntax-rule (with-fixture-answer identifier body ...)
  (let ([identifier (fixture-answer)])
    body ...))

(module+ main
  (displayln (fixture-answer)))
