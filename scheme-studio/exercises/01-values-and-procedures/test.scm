(use-modules (srfi srfi-64))

(let ((arguments (cdr (command-line))))
  (unless (= (length arguments) 1)
    (error "usage: test.scm SOLUTION"))
  (primitive-load (car arguments)))

(test-begin "01-values-and-procedures")
(test-equal "square positive" 25 (square 5))
(test-equal "square negative" 16 (square -4))
(test-equal "square zero" 0 (square 0))
(test-equal "sum of squares" 25 (sum-of-squares 3 4))

(let ((runner (test-runner-current)))
  (test-end "01-values-and-procedures")
  (exit (if (zero? (+ (test-runner-fail-count runner)
                       (test-runner-xpass-count runner)))
            0
            1)))
