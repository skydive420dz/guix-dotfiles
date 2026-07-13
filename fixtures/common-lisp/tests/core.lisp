(in-package #:sk-fixture/tests)

(defun check-equal (expected actual label)
  "Signal an error unless EXPECTED and ACTUAL are equal for LABEL."
  (unless (equal expected actual)
    (error "~A: expected ~S, got ~S" label expected actual))
  actual)

(defun run-tests ()
  "Run the dependency-free sk-fixture test suite."
  (check-equal 42 (add 20 22) "ADD")
  (check-equal 42 (twice 21) "TWICE")
  (format t "sk-fixture/tests: PASS~%")
  t)
