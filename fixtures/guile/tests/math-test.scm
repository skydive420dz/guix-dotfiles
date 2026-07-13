;;; math-test.scm --- SRFI-64 checks for the Guile fixture

(use-modules (sk fixture math)
             (srfi srfi-64))

(test-begin "fixture-math")

(test-equal "addition" 42 (fixture-add 20 22))
(test-equal "doubling" 42 (fixture-double 21))
(test-equal "answer" 42 (fixture-answer))

;; SRFI-64 reports failures but does not promise a failing process status.
;; Translate both ordinary failures and unexpected passes into a CLI failure.
(let ((runner (test-runner-current)))
  (test-end "fixture-math")
  (exit (if (zero? (+ (test-runner-fail-count runner)
                       (test-runner-xpass-count runner)))
            0
            1)))

;;; math-test.scm ends here
