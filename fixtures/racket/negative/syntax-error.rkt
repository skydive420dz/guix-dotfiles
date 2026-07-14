#lang racket/base

;; Deliberately unclosed: the compile negative control must reject this file.
(define (broken value)
  (+ value 1)
