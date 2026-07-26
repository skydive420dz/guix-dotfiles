(use-modules (srfi srfi-64))

(let ((arguments (cdr (command-line))))
  (unless (= (length arguments) 1)
    (error "usage: test.scm SOLUTION"))
  (primitive-load (car arguments)))

(test-begin "03-higher-order-procedures")
(test-equal "keep empty" '() (keep even? '()))
(test-equal "keep matching" '(2 4) (keep even? '(1 2 3 4 5)))
(test-equal "keep none" '() (keep negative? '(0 1 2)))
(test-equal "compose"
  21
  ((compose (lambda (number) (* number 3))
            (lambda (number) (+ number 2)))
   5))

(let ((runner (test-runner-current)))
  (test-end "03-higher-order-procedures")
  (exit (if (zero? (+ (test-runner-fail-count runner)
                       (test-runner-xpass-count runner)))
            0
            1)))
