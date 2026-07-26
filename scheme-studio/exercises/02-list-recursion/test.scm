(use-modules (srfi srfi-64))

(let ((arguments (cdr (command-line))))
  (unless (= (length arguments) 1)
    (error "usage: test.scm SOLUTION"))
  (primitive-load (car arguments)))

(test-begin "02-list-recursion")
(test-equal "sum empty" 0 (sum-list '()))
(test-equal "sum values" 10 (sum-list '(1 2 3 4)))
(test-equal "squares empty" '() (squares '()))
(test-equal "squares values" '(1 4 9 16) (squares '(1 2 3 4)))

(let ((runner (test-runner-current)))
  (test-end "02-list-recursion")
  (exit (if (zero? (+ (test-runner-fail-count runner)
                       (test-runner-xpass-count runner)))
            0
            1)))
