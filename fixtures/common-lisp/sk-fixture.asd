(asdf:defsystem "sk-fixture"
  :description "Dependency-free Common Lisp project acceptance fixture"
  :version "0.1.0"
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "package")
                             (:file "core"))))
  :in-order-to ((test-op (test-op "sk-fixture/tests"))))

(asdf:defsystem "sk-fixture/tests"
  :description "Tests for the sk-fixture system"
  :depends-on ("sk-fixture")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "package")
                             (:file "core"))))
  :perform (test-op (operation component)
             (declare (ignore operation component))
             (uiop:symbol-call :sk-fixture/tests :run-tests)))
